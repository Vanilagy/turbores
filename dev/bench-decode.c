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
 * Takes a video file, extracts ALL of its ProRes packets into memory via the Mediabunny-based node extractor
 * (dev/extract-packets.mjs), then decodes the whole sequence through turbores. The full-file decode is repeated
 * several times; it reports throughput (FPS), time per frame, and time per full-file decode.
 *
 * Build & run via dev/run-native-bench.sh, or manually:
 *   gcc -O3 dev/bench-decode.c -Idev -o build/bench-decode -Lbuild -lturbores-x86_64
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

#include "packet-source.h"
#include "turbores.h"

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec + (double) ts.tv_nsec * 1e-9;
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

    double *run_times = NULL;
    Decoder *decoder = NULL;
    Frame *frame = NULL;

    /* --- Extract all video packets into memory via the Mediabunny node extractor --- */

    PacketSet set;
    if (load_packets(video_path, &set) != 0) {
        return 1;
    }
    if (set.count == 0) {
        fprintf(stderr, "No video packets extracted from %s\n", video_path);
        free_packets(&set);
        return 1;
    }

    //long logical_cores = sysconf(_SC_NPROCESSORS_ONLN);

    printf("File:          %s\n", video_path);
    printf("Resolution:    %dx%d\n", set.width, set.height);
    printf("Bit depth:     %u\n", set.bit_depth);
    printf("Concurrency:   %u worker thread(s)\n", concurrency);
    //printf("Logical cores: %ld\n", logical_cores);
    printf("Packets/frame: %zu extracted\n", set.count);
    printf("Repeats:       %ld\n", repeats);

    /* --- Decode the whole sequence repeatedly through turbores --- */

    decoder = createDecoder(concurrency, set.bit_depth, 0xffffffff);
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
    for (size_t i = 0; i < set.count; i++) {
        uint8_t *dst = allocatePacket(decoder, set.packets[i].size);
        if (!dst) {
            fprintf(stderr, "allocatePacket failed\n");
            goto cleanup;
        }
        memcpy(dst, set.packets[i].data, set.packets[i].size);

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

        for (size_t i = 0; i < set.count; i++) {
            /* Feeding the packet (allocate + copy into the decoder) is part of decoding the file, so it's timed. */
            uint8_t *dst = allocatePacket(decoder, set.packets[i].size);
            if (!dst) {
                fprintf(stderr, "allocatePacket failed\n");
                goto cleanup;
            }
            memcpy(dst, set.packets[i].data, set.packets[i].size);

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

    double total_frames = (double) set.count * (double) repeats;
    double avg_run = total_time / (double) repeats;
    double per_frame_ms = (total_time / total_frames) * 1000.0;
    double fps = total_frames / total_time;

    printf("\n");
    printf("Frames decoded:    %.0f (%zu frames x %ld repeats)\n", total_frames, set.count, repeats);
    printf("Total time:        %.3f s\n", total_time);
    printf("Per full-file:     %.3f s avg  (best %.3f s, worst %.3f s)\n", avg_run, best_run, worst_run);
    printf("Per frame:         %.3f ms\n", per_frame_ms);
    printf("Throughput:        %.1f FPS\n", fps);

    exit_code = 0;

cleanup:
    if (frame) closeFrame(frame);
    if (decoder) closeDecoder(decoder);
    free(run_times);
    free_packets(&set);
    return exit_code;
}
