/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Smoke test for the native turbores library: loads a ProRes packet, decodes it with worker threads, and compares
 * the decoded frame data against a gzipped reference produced by the JS/WASM decoder.
 *
 * Build & run via dev/run-native-test.sh, or manually:
 *   gcc dev/test-decode.c -Ibuild -o build/test-decode -Lbuild -lturbores-x86_64 -lz
 *   LD_LIBRARY_PATH=build ./build/test-decode tests/public/buck-bunny.prores tests/public/buck-bunny.framedata.gz 10 4
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include "turbores.h"

/* Reads an entire file into a freshly allocated buffer. Returns the buffer (caller frees) and sets *out_size. */
static uint8_t *read_file(const char *path, size_t *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Failed to open %s\n", path);
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size < 0) {
        fclose(f);
        return NULL;
    }

    uint8_t *buf = malloc((size_t) size);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    if (fread(buf, 1, (size_t) size, f) != (size_t) size) {
        fprintf(stderr, "Failed to read %s\n", path);
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *out_size = (size_t) size;
    return buf;
}

/* Decompresses a gzip file into a growable buffer. Returns the buffer (caller frees) and sets *out_size. */
static uint8_t *read_gzip(const char *path, size_t *out_size) {
    gzFile gz = gzopen(path, "rb");
    if (!gz) {
        fprintf(stderr, "Failed to open gzip %s\n", path);
        return NULL;
    }

    size_t cap = 1 << 20;
    size_t len = 0;
    uint8_t *buf = malloc(cap);
    if (!buf) {
        gzclose(gz);
        return NULL;
    }

    for (;;) {
        if (len == cap) {
            cap *= 2;
            uint8_t *next = realloc(buf, cap);
            if (!next) {
                free(buf);
                gzclose(gz);
                return NULL;
            }
            buf = next;
        }

        int n = gzread(gz, buf + len, (unsigned) (cap - len));
        if (n < 0) {
            fprintf(stderr, "gzread error on %s\n", path);
            free(buf);
            gzclose(gz);
            return NULL;
        }
        if (n == 0) {
            break;
        }
        len += (size_t) n;
    }

    gzclose(gz);
    *out_size = len;
    return buf;
}

int main(int argc, char **argv) {
    const char *prores_path = argc > 1 ? argv[1] : "tests/public/buck-bunny.prores";
    const char *reference_path = argc > 2 ? argv[2] : "tests/public/buck-bunny.framedata.gz";
    uint32_t bit_depth = argc > 3 ? (uint32_t) strtoul(argv[3], NULL, 10) : 10;
    uint32_t concurrency = argc > 4 ? (uint32_t) strtoul(argv[4], NULL, 10) : 4;

    printf("Packet:      %s\n", prores_path);
    printf("Reference:   %s\n", reference_path);
    printf("Bit depth:   %u\n", bit_depth);
    printf("Concurrency: %u\n", concurrency);

    size_t packet_size = 0;
    uint8_t *packet = read_file(prores_path, &packet_size);
    if (!packet) {
        return 1;
    }
    printf("Packet size: %zu bytes\n", packet_size);

    size_t reference_size = 0;
    uint8_t *reference = read_gzip(reference_path, &reference_size);
    if (!reference) {
        free(packet);
        return 1;
    }
    printf("Reference frame data: %zu bytes\n", reference_size);

    Decoder *decoder = createDecoder(concurrency, bit_depth, 0xffffffff);
    if (!decoder) {
        fprintf(stderr, "createDecoder failed\n");
        free(packet);
        free(reference);
        return 1;
    }

    Frame *frame = createFrame();
    if (!frame) {
        fprintf(stderr, "createFrame failed\n");
        closeDecoder(decoder);
        free(packet);
        free(reference);
        return 1;
    }

    uint8_t *packet_dst = allocatePacket(decoder, packet_size);
    if (!packet_dst) {
        fprintf(stderr, "allocatePacket failed\n");
        goto fail;
    }
    memcpy(packet_dst, packet, packet_size);

    int32_t code = decodePacket(decoder, frame);
    if (code < 0) {
        fprintf(stderr, "decodePacket failed with code %d\n", code);
        size_t msg_size = getErrorMessageSize(decoder);
        const uint8_t *msg = getErrorMessagePtr(decoder);
        if (msg && msg_size) {
            fprintf(stderr, "  message: %.*s\n", (int) msg_size, msg);
        }
        goto fail;
    }

    if (concurrency > 0) {
        waitForCompletion(decoder);
        code = finalizePacketDecoding(decoder);
        if (code < 0) {
            fprintf(stderr, "finalizePacketDecoding failed with code %d\n", code);
            size_t msg_size = getErrorMessageSize(decoder);
            const uint8_t *msg = getErrorMessagePtr(decoder);
            if (msg && msg_size) {
                fprintf(stderr, "  message: %.*s\n", (int) msg_size, msg);
            }
            goto fail;
        }
    }

    printf("Coded size:  %ux%u\n", getCodedWidth(frame), getCodedHeight(frame));
    printf("Visible:     %ux%u\n", getVisibleWidth(frame), getVisibleHeight(frame));

    size_t frame_size = getFrameDataSize(frame);
    const uint8_t *frame_data = getFrameDataPtr(frame);
    printf("Decoded frame data: %zu bytes\n", frame_size);

    if (frame_size != reference_size) {
        fprintf(stderr, "FAIL: size mismatch (decoded %zu, reference %zu)\n", frame_size, reference_size);
        goto fail;
    }

    if (memcmp(frame_data, reference, frame_size) != 0) {
        /* Report the first differing byte for debugging. */
        size_t i = 0;
        while (i < frame_size && frame_data[i] == reference[i]) {
            i++;
        }
        fprintf(stderr, "FAIL: byte mismatch at offset %zu (decoded %u, reference %u)\n",
                i, frame_data[i], reference[i]);
        goto fail;
    }

    printf("PASS: decoded frame matches reference exactly.\n");

    closeFrame(frame);
    closeDecoder(decoder);
    free(packet);
    free(reference);
    return 0;

fail:
    closeFrame(frame);
    closeDecoder(decoder);
    free(packet);
    free(reference);
    return 1;
}
