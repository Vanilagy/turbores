/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Decode-performance benchmark for the native turbores library.
 *
 * Takes a video file, demuxes ALL of its ProRes packets into memory using FFmpeg's libavformat, then decodes the
 * whole sequence through turbores. The full-file decode is repeated several times; it reports throughput (FPS), time
 * per frame, and time per full-file decode.
 *
 * Build & run via dev/run-native-bench.sh, or manually:
 *   gcc -O2 dev/bench-decode.c -Idev -o build/bench-decode -Lbuild -lturbores-x86_64 \
 *       $(pkg-config --cflags --libs libavformat libavcodec libavutil)
 *   LD_LIBRARY_PATH=build ./build/bench-decode some-prores.mov 12
 *
 * Usage:
 *   bench-decode <video-file> <concurrency> [repeats]
 *
 *   <video-file>   Path to a ProRes-encoded video file (required).
 *   <concurrency>  Number of worker threads to decode with (required). 0 = decode synchronously.
 *   [repeats]      How many times to decode the whole file (default 10).
 */

#define _POSIX_C_SOURCE 199309L

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

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec + (double) ts.tv_nsec * 1e-9;
}

/* ProRes 4444 / 4444 XQ are 12-bit; all other ProRes profiles are 10-bit. */
static uint32_t bit_depth_for_tag(uint32_t codec_tag) {
    char t[5] = { 0 };
    memcpy(t, &codec_tag, 4); /* codec_tag stores the fourcc little-endian, i.e. as ascii bytes */
    if (memcmp(t, "ap4h", 4) == 0 || memcmp(t, "ap4x", 4) == 0) {
        return 12;
    }
    return 10;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <video-file> <concurrency> [repeats]\n", argv[0]);
        return 2;
    }

    const char *video_path = argv[1];
    uint32_t concurrency = (uint32_t) strtoul(argv[2], NULL, 10);
    long repeats = argc > 3 ? strtol(argv[3], NULL, 10) : 10;
    if (repeats <= 0) {
        fprintf(stderr, "repeats must be positive\n");
        return 2;
    }

    int exit_code = 1;

    StoredPacket *packets = NULL;
    size_t packet_count = 0;
    size_t packet_cap = 0;
    double *run_times = NULL;

    Decoder *decoder = NULL;
    Frame *frame = NULL;

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
                    goto cleanup_demux;
                }
                packets = next;
            }

            uint8_t *copy = malloc((size_t) pkt->size);
            if (!copy) {
                fprintf(stderr, "Out of memory copying packet\n");
                av_packet_unref(pkt);
                goto cleanup_demux;
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

    long logical_cores = sysconf(_SC_NPROCESSORS_ONLN);

    printf("File:          %s\n", video_path);
    printf("Codec:         ProRes (%s)\n", fourcc);
    printf("Resolution:    %dx%d\n", width, height);
    printf("Bit depth:     %u\n", bit_depth);
    printf("Concurrency:   %u worker thread(s)\n", concurrency);
    printf("Logical cores: %ld\n", logical_cores);
    printf("Packets/frame: %zu extracted\n", packet_count);
    printf("Repeats:       %ld\n", repeats);

    /* --- Decode the whole sequence repeatedly through turbores --- */

    decoder = createDecoder(concurrency, bit_depth, 0xffffffff);
    if (!decoder) {
        fprintf(stderr, "createDecoder failed\n");
        goto cleanup;
    }
    frame = createFrame();
    if (!frame) {
        fprintf(stderr, "createFrame failed\n");
        goto cleanup;
    }

    run_times = malloc((size_t) repeats * sizeof(*run_times));
    if (!run_times) {
        fprintf(stderr, "Out of memory\n");
        goto cleanup;
    }

    printf("\nWarming up...\n");
    /* One untimed pass over the whole file to spin up the worker pool and fault in buffers. */
    for (size_t i = 0; i < packet_count; i++) {
        uint8_t *dst = allocatePacket(decoder, packets[i].size);
        if (!dst) {
            fprintf(stderr, "allocatePacket failed\n");
            goto cleanup;
        }
        memcpy(dst, packets[i].data, packets[i].size);

        int32_t code = decodePacket(decoder, frame);
        if (code >= 0 && concurrency > 0) {
            waitForCompletion(decoder);
            code = finalizePacketDecoding(decoder);
        }
        if (code < 0) {
            fprintf(stderr, "Decode failed on packet %zu with code %d\n", i, code);
            goto cleanup;
        }
    }

    printf("Benchmarking...\n");
    double total_time = 0.0;
    for (long r = 0; r < repeats; r++) {
        double run_start = now_seconds();

        for (size_t i = 0; i < packet_count; i++) {
            /* Feeding the packet (allocate + copy into the decoder) is part of decoding the file, so it's timed. */
            uint8_t *dst = allocatePacket(decoder, packets[i].size);
            if (!dst) {
                fprintf(stderr, "allocatePacket failed\n");
                goto cleanup;
            }
            memcpy(dst, packets[i].data, packets[i].size);

            int32_t code = decodePacket(decoder, frame);
            if (code >= 0 && concurrency > 0) {
                waitForCompletion(decoder);
                code = finalizePacketDecoding(decoder);
            }
            if (code < 0) {
                fprintf(stderr, "Decode failed on packet %zu with code %d\n", i, code);
                goto cleanup;
            }
        }

        double run_time = now_seconds() - run_start;
        run_times[r] = run_time;
        total_time += run_time;
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
    if (frame) closeFrame(frame);
    if (decoder) closeDecoder(decoder);
    free(run_times);
    for (size_t i = 0; i < packet_count; i++) {
        free(packets[i].data);
    }
    free(packets);
    return exit_code;

cleanup_demux:
    if (pkt) av_packet_free(&pkt);
    if (fmt_ctx) avformat_close_input(&fmt_ctx);
    for (size_t i = 0; i < packet_count; i++) {
        free(packets[i].data);
    }
    free(packets);
    return 1;
}
