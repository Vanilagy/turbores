/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Alternative decode-performance benchmark exploring a DIFFERENT threading model than turbores' built-in one.
 *
 * turbores normally multithreads *within* a single frame (slices of one packet are decoded in parallel), which is
 * great for latency but scales worse than FFmpeg's frame-threading. This benchmark instead mimics FFmpeg's "one
 * thread per packet" approach: it creates `concurrency` independent *synchronous* decoders (each internal
 * concurrency = 0) and runs them on `concurrency` OS threads, statically round-robin-assigning packets to decoders
 * (packet i -> decoder i % concurrency). Each thread decodes whole frames on its own; there is no intra-frame
 * parallelism.
 *
 * This is a temporary experiment to see the throughput ceiling of frame-level parallelism for turbores.
 *
 * Build & run via dev/run-native-bench-2.sh, or manually:
 *   gcc -O3 -pthread dev/bench-decode-2.c -Idev -o build/bench-decode-2 -Lbuild -lturbores-x86_64 \
 *       $(pkg-config --cflags --libs libavformat libavcodec libavutil)
 *   LD_LIBRARY_PATH=build ./build/bench-decode-2 some-prores.mov 12
 *
 * Usage:
 *   bench-decode-2 <video-file> <concurrency> [repeats]
 *
 *   <video-file>   Path to a ProRes-encoded video file (required).
 *   <concurrency>  Number of decoders / OS threads (required, >= 1).
 *   [repeats]      How many times to decode the whole file (default 10).
 */

#define _POSIX_C_SOURCE 200112L

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

#include "turbores.h"

/* A single demuxed packet held in memory. */
typedef struct {
    uint8_t *data;
    size_t size;
} StoredPacket;

/* Shared state visible to all worker threads (read-only during a pass). */
typedef struct {
    const StoredPacket *packets;
    size_t packet_count;
    uint32_t concurrency;
    long total_passes; /* warm-up + timed */

    pthread_barrier_t start_barrier; /* released to begin each pass */
    pthread_barrier_t end_barrier;   /* met when all threads finish a pass */

    atomic_int failed;     /* set if any thread hits a decode error */
    atomic_int error_code; /* the first error code seen */
} Shared;

/* Per-thread state. */
typedef struct {
    Shared *shared;
    uint32_t thread_id;
    Decoder *decoder; /* this thread's private decoder (internal concurrency = 0) */
    Frame *frame;     /* this thread's private frame */
} Worker;

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec + (double) ts.tv_nsec * 1e-9;
}

/* ProRes 4444 / 4444 XQ are 12-bit; all other ProRes profiles are 10-bit. */
static uint32_t bit_depth_for_tag(uint32_t codec_tag) {
    char t[5] = { 0 };
    memcpy(t, &codec_tag, 4);
    if (memcmp(t, "ap4h", 4) == 0 || memcmp(t, "ap4x", 4) == 0) {
        return 12;
    }
    return 10;
}

static void *worker_main(void *arg) {
    Worker *w = (Worker *) arg;
    Shared *s = w->shared;

    for (long pass = 0; pass < s->total_passes; pass++) {
        pthread_barrier_wait(&s->start_barrier);

        /* Decode this thread's round-robin share of the packets, unless someone already failed. */
        if (!atomic_load_explicit(&s->failed, memory_order_relaxed)) {
            for (size_t i = w->thread_id; i < s->packet_count; i += s->concurrency) {
                uint8_t *dst = allocatePacket(w->decoder, s->packets[i].size);
                if (!dst) {
                    atomic_store(&s->error_code, -1);
                    atomic_store(&s->failed, 1);
                    break;
                }
                memcpy(dst, s->packets[i].data, s->packets[i].size);

                /* Internal concurrency is 0, so decodePacket fully decodes synchronously on this thread. */
                int32_t code = decodePacket(w->decoder, w->frame);
                if (code < 0) {
                    atomic_store(&s->error_code, code);
                    atomic_store(&s->failed, 1);
                    break;
                }
            }
        }

        pthread_barrier_wait(&s->end_barrier);
    }

    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <video-file> <concurrency> [repeats]\n", argv[0]);
        return 2;
    }

    const char *video_path = argv[1];
    uint32_t concurrency = (uint32_t) strtoul(argv[2], NULL, 10);
    long repeats = argc > 3 ? strtol(argv[3], NULL, 10) : 10;
    if (concurrency < 1) {
        fprintf(stderr, "concurrency must be >= 1\n");
        return 2;
    }
    if (repeats <= 0) {
        fprintf(stderr, "repeats must be positive\n");
        return 2;
    }

    int exit_code = 1;

    StoredPacket *packets = NULL;
    size_t packet_count = 0;
    size_t packet_cap = 0;
    double *run_times = NULL;

    Worker *workers = NULL;
    pthread_t *threads = NULL;
    uint32_t spawned = 0;
    Shared shared;
    memset(&shared, 0, sizeof(shared));
    int barriers_inited = 0;

    /* --- Demux all video packets into memory using libavformat --- */

    AVFormatContext *fmt_ctx = NULL;
    if (avformat_open_input(&fmt_ctx, video_path, NULL, NULL) < 0) {
        fprintf(stderr, "Failed to open %s\n", video_path);
        return 1;
    }
    if (avformat_find_stream_info(fmt_ctx, NULL) < 0) {
        fprintf(stderr, "Failed to read stream info from %s\n", video_path);
        avformat_close_input(&fmt_ctx);
        return 1;
    }

    int video_index = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (video_index < 0) {
        fprintf(stderr, "No video stream found in %s\n", video_path);
        avformat_close_input(&fmt_ctx);
        return 1;
    }

    AVCodecParameters *par = fmt_ctx->streams[video_index]->codecpar;
    if (par->codec_id != AV_CODEC_ID_PRORES) {
        fprintf(stderr, "Video stream is not ProRes (codec id %d); turbores can't decode it.\n", par->codec_id);
        avformat_close_input(&fmt_ctx);
        return 1;
    }

    uint32_t bit_depth = bit_depth_for_tag(par->codec_tag);
    int width = par->width;
    int height = par->height;
    char fourcc[5] = { 0 };
    memcpy(fourcc, &par->codec_tag, 4);

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) {
        fprintf(stderr, "av_packet_alloc failed\n");
        avformat_close_input(&fmt_ctx);
        return 1;
    }

    while (av_read_frame(fmt_ctx, pkt) >= 0) {
        if (pkt->stream_index == video_index && pkt->size > 0) {
            if (packet_count == packet_cap) {
                packet_cap = packet_cap ? packet_cap * 2 : 256;
                StoredPacket *next = realloc(packets, packet_cap * sizeof(*packets));
                if (!next) {
                    fprintf(stderr, "Out of memory storing packets\n");
                    av_packet_unref(pkt);
                    av_packet_free(&pkt);
                    avformat_close_input(&fmt_ctx);
                    goto cleanup;
                }
                packets = next;
            }

            uint8_t *copy = malloc((size_t) pkt->size);
            if (!copy) {
                fprintf(stderr, "Out of memory copying packet\n");
                av_packet_unref(pkt);
                av_packet_free(&pkt);
                avformat_close_input(&fmt_ctx);
                goto cleanup;
            }
            memcpy(copy, pkt->data, (size_t) pkt->size);
            packets[packet_count].data = copy;
            packets[packet_count].size = (size_t) pkt->size;
            packet_count++;
        }
        av_packet_unref(pkt);
    }

    av_packet_free(&pkt);
    avformat_close_input(&fmt_ctx);
    fmt_ctx = NULL;

    if (packet_count == 0) {
        fprintf(stderr, "No video packets extracted from %s\n", video_path);
        goto cleanup;
    }

    /* Don't spawn more threads than there are packets. */
    if (concurrency > packet_count) {
        concurrency = (uint32_t) packet_count;
    }

    long logical_cores = sysconf(_SC_NPROCESSORS_ONLN);

    printf("File:          %s\n", video_path);
    printf("Codec:         ProRes (%s)\n", fourcc);
    printf("Resolution:    %dx%d\n", width, height);
    printf("Bit depth:     %u\n", bit_depth);
    printf("Model:         frame-parallel (%u synchronous decoders, round-robin)\n", concurrency);
    printf("Logical cores: %ld\n", logical_cores);
    printf("Packets/frame: %zu extracted\n", packet_count);
    printf("Repeats:       %ld\n", repeats);

    /* --- Set up the per-thread decoders/frames and the synchronization --- */

    shared.packets = packets;
    shared.packet_count = packet_count;
    shared.concurrency = concurrency;
    shared.total_passes = repeats + 1; /* +1 untimed warm-up pass */
    atomic_store(&shared.failed, 0);
    atomic_store(&shared.error_code, 0);

    if (pthread_barrier_init(&shared.start_barrier, NULL, concurrency + 1) != 0
        || pthread_barrier_init(&shared.end_barrier, NULL, concurrency + 1) != 0) {
        fprintf(stderr, "pthread_barrier_init failed\n");
        goto cleanup;
    }
    barriers_inited = 1;

    workers = calloc(concurrency, sizeof(*workers));
    threads = calloc(concurrency, sizeof(*threads));
    run_times = malloc((size_t) repeats * sizeof(*run_times));
    if (!workers || !threads || !run_times) {
        fprintf(stderr, "Out of memory\n");
        goto cleanup;
    }

    for (uint32_t t = 0; t < concurrency; t++) {
        workers[t].shared = &shared;
        workers[t].thread_id = t;
        /* Internal concurrency 0 => each decoder decodes synchronously on its owning thread. */
        workers[t].decoder = createDecoder(0, bit_depth, 0xffffffff);
        workers[t].frame = createFrame();
        if (!workers[t].decoder || !workers[t].frame) {
            fprintf(stderr, "Failed to create decoder/frame %u\n", t);
            goto cleanup;
        }
    }

    for (uint32_t t = 0; t < concurrency; t++) {
        if (pthread_create(&threads[t], NULL, worker_main, &workers[t]) != 0) {
            /* Threads already spawned are blocked on a barrier sized for the full count, so we can't cleanly
             * unwind here. This is a benchmark and pthread_create realistically never fails, so just bail hard. */
            fprintf(stderr, "pthread_create failed for thread %u\n", t);
            exit(1);
        }
        spawned++;
    }

    /* --- Drive the passes from the main thread --- */

    printf("\nWarming up...\n");
    double total_time = 0.0;
    for (long pass = 0; pass < shared.total_passes; pass++) {
        pthread_barrier_wait(&shared.start_barrier);
        double t0 = now_seconds();

        pthread_barrier_wait(&shared.end_barrier);
        double elapsed = now_seconds() - t0;

        if (pass == 0) {
            printf("Benchmarking...\n");
            continue; /* warm-up not recorded */
        }

        run_times[pass - 1] = elapsed;
        total_time += elapsed;
    }

    /* All passes done; join the threads. */
    for (uint32_t t = 0; t < spawned; t++) {
        pthread_join(threads[t], NULL);
    }
    spawned = 0;

    if (atomic_load(&shared.failed)) {
        fprintf(stderr, "Decode failed with code %d\n", atomic_load(&shared.error_code));
        goto cleanup;
    }

    /* --- Report --- */

    double best_run = run_times[0];
    double worst_run = run_times[0];
    for (long r = 1; r < repeats; r++) {
        if (run_times[r] < best_run) best_run = run_times[r];
        if (run_times[r] > worst_run) worst_run = run_times[r];
    }

    double total_frames = (double) packet_count * (double) repeats;
    double avg_run = total_time / (double) repeats;
    double per_frame_ms = (total_time / total_frames) * 1000.0;
    double fps = total_frames / total_time;

    printf("\n");
    printf("Frames decoded:    %.0f (%zu frames x %ld repeats)\n", total_frames, packet_count, repeats);
    printf("Total time:        %.3f s\n", total_time);
    printf("Per full-file:     %.3f s avg  (best %.3f s, worst %.3f s)\n", avg_run, best_run, worst_run);
    printf("Per frame:         %.3f ms\n", per_frame_ms);
    printf("Throughput:        %.1f FPS\n", fps);

    exit_code = 0;

cleanup:
    /* Threads are always joined on the normal and decode-error paths before reaching here (spawned reset to 0).
     * Any goto cleanup before/after spawning therefore has no live threads to release. */
    if (barriers_inited) {
        pthread_barrier_destroy(&shared.start_barrier);
        pthread_barrier_destroy(&shared.end_barrier);
    }

    if (workers) {
        for (uint32_t t = 0; t < concurrency; t++) {
            if (workers[t].frame) closeFrame(workers[t].frame);
            if (workers[t].decoder) closeDecoder(workers[t].decoder);
        }
    }
    free(workers);
    free(threads);
    free(run_times);
    for (size_t i = 0; i < packet_count; i++) {
        free(packets[i].data);
    }
    free(packets);
    return exit_code;
}
