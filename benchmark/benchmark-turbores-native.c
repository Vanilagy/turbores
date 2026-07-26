/*
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

// Benchmarks decoding of a real video file. A node child process demuxes it via Mediabunny and streams all video
// packets over, which we keep in RAM, then we decode the whole file ten times (after one warmup iteration) with a
// single decoder and frame. Run via benchmark-turbores-native.sh, which builds the library first.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../src/turbores.h"

#define ITERATIONS 10

typedef struct Packet {
    uint8_t *data;
    size_t size;
} Packet;

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec + (double) ts.tv_nsec / 1e9;
}

static int decodeFile(TurboresDecoder *decoder, TurboresFrame *frame, Packet *packets, size_t packet_count) {
    for (size_t p = 0; p < packet_count; p++) {
        int32_t result = turbores_decode(decoder, frame, packets[p].data, packets[p].size);
        if (result != 0) {
            const uint8_t *message = turbores_decoder_error_message_ptr(decoder);
            fprintf(
                stderr,
                "turbores_decode failed on packet %zu with code %d: %.*s\n",
                p,
                result,
                (int) turbores_decoder_error_message_size(decoder),
                message ? (const char *) message : ""
            );
            return 1;
        }
    }

    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <video-file> <threads>\n", argv[0]);
        return 1;
    }

    const char *path = argv[1];
    uint32_t threads = (uint32_t) atoi(argv[2]);

    char command[4096];
    snprintf(command, sizeof(command), "npx tsx scripts/stream-packets-to-stdout.ts \"%s\"", path);

    FILE *pipe = popen(command, "r");
    if (!pipe) {
        fprintf(stderr, "Failed to spawn node child process\n");
        return 1;
    }

    char four_cc[5] = { 0 };
    if (fread(four_cc, 1, 4, pipe) != 4) {
        fprintf(stderr, "Failed to read fourcc from child process\n");
        return 1;
    }

    Packet *packets = NULL;
    size_t packet_count = 0;
    size_t packet_capacity = 0;
    size_t total_bytes = 0;

    while (1) {
        uint32_t size;
        if (fread(&size, 1, 4, pipe) != 4) {
            break; // EOF, all packets received
        }

        uint8_t *data = malloc(size);
        if (fread(data, 1, size, pipe) != size) {
            fprintf(stderr, "Truncated packet from child process\n");
            return 1;
        }

        if (packet_count == packet_capacity) {
            packet_capacity = packet_capacity == 0 ? 64 : packet_capacity * 2;
            packets = realloc(packets, packet_capacity * sizeof(Packet));
        }
        packets[packet_count++] = (Packet) { data, size };
        total_bytes += size;
    }

    if (pclose(pipe) != 0) {
        fprintf(stderr, "node child process failed\n");
        return 1;
    }
    if (packet_count == 0) {
        fprintf(stderr, "No packets received\n");
        return 1;
    }

    uint32_t bit_depth = (strcmp(four_cc, "ap4h") == 0 || strcmp(four_cc, "ap4x") == 0) ? 12 : 10;
    printf(
        "Loaded %zu packets (%.1f MB) from %s (fourcc %s, bit depth %u, threads %u)\n",
        packet_count, (double) total_bytes / 1e6, path, four_cc, bit_depth, threads
    );

    TurboresDecoder *decoder = turbores_decoder_create(threads, bit_depth, TURBORES_ALL_PIXEL_FORMATS);
    TurboresFrame *frame = turbores_frame_create();

    // Warmup, not sure if this needed tbh
    if (decodeFile(decoder, frame, packets, packet_count) != 0) {
        return 1;
    }

    double start = now();

    for (int i = 0; i < ITERATIONS; i++) {
        if (decodeFile(decoder, frame, packets, packet_count) != 0) {
            return 1;
        }
    }

    double seconds = now() - start;
    int total_frames = ITERATIONS * (int) packet_count;

    printf("Decoded %d x %zu frames in %.3f s\n", ITERATIONS, packet_count, seconds);
    printf("Time per file:  %.3f ms\n", seconds / ITERATIONS * 1e3);
    printf("Time per frame: %.3f ms\n", seconds / total_frames * 1e3);
    printf("FPS: %.1f\n", total_frames / seconds);

    return 0;
}
