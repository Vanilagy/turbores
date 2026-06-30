/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Loads all ProRes packets of a video file by spawning the Mediabunny-based extractor (dev/extract-packets.mjs) and
 * reading its framed binary output from a pipe. This keeps the native benchmarks free of any FFmpeg/libavformat
 * build dependency.
 *
 * The path to the node script defaults to "dev/extract-packets.mjs" (resolved relative to the process's working
 * directory, i.e. the repo root when launched via the dev/run-*.sh scripts) and can be overridden with the
 * TURBORES_EXTRACTOR environment variable.
 */

#ifndef PACKET_SOURCE_H
#define PACKET_SOURCE_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct {
    uint8_t *data;
    size_t size;
} StoredPacket;

typedef struct {
    StoredPacket *packets;
    size_t count;
    uint32_t bit_depth;
    int width;
    int height;
} PacketSet;

/* Reads exactly n bytes into buf; returns 0 on success, -1 on short read / error. */
static int ps_read_full(FILE *f, void *buf, size_t n) {
    return fread(buf, 1, n, f) == n ? 0 : -1;
}

/* Spawns `node <extractor> <video_path>` and reads the framed packet stream from its stdout into `set`.
 * Returns 0 on success. On success the caller must call free_packets(set). */
static int load_packets(const char *video_path, PacketSet *set) {
    const char *script = getenv("TURBORES_EXTRACTOR");
    if (!script || !*script) {
        script = "dev/extract-packets.mjs";
    }

    set->packets = NULL;
    set->count = 0;
    set->bit_depth = 0;
    set->width = 0;
    set->height = 0;

    int fds[2];
    if (pipe(fds) != 0) {
        perror("pipe");
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    if (pid == 0) {
        /* Child: send stdout down the pipe and exec node. */
        dup2(fds[1], STDOUT_FILENO);
        close(fds[0]);
        close(fds[1]);
        execlp("node", "node", script, video_path, (char *) NULL);
        perror("execlp node");
        _exit(127);
    }

    /* Parent. */
    close(fds[1]);
    FILE *in = fdopen(fds[0], "rb");
    if (!in) {
        perror("fdopen");
        close(fds[0]);
        waitpid(pid, NULL, 0);
        return -1;
    }

    int rc = -1;
    size_t cap = 0;

    char magic[4];
    uint32_t hdr[3];
    if (ps_read_full(in, magic, 4) != 0 || memcmp(magic, "TRP1", 4) != 0) {
        fprintf(stderr, "extractor: missing/invalid header (is node + mediabunny available?)\n");
        goto done;
    }
    if (ps_read_full(in, hdr, sizeof(hdr)) != 0) {
        fprintf(stderr, "extractor: short header\n");
        goto done;
    }
    set->bit_depth = hdr[0];
    set->width = (int) hdr[1];
    set->height = (int) hdr[2];

    for (;;) {
        uint32_t size;
        size_t got = fread(&size, 1, 4, in);
        if (got == 0) {
            break; /* clean EOF */
        }
        if (got != 4) {
            fprintf(stderr, "extractor: truncated packet size\n");
            goto done;
        }

        if (set->count == cap) {
            cap = cap ? cap * 2 : 256;
            StoredPacket *next = realloc(set->packets, cap * sizeof(*next));
            if (!next) {
                fprintf(stderr, "Out of memory storing packets\n");
                goto done;
            }
            set->packets = next;
        }

        uint8_t *data = malloc(size ? size : 1);
        if (!data) {
            fprintf(stderr, "Out of memory copying packet\n");
            goto done;
        }
        if (size && ps_read_full(in, data, size) != 0) {
            fprintf(stderr, "extractor: truncated packet data\n");
            free(data);
            goto done;
        }
        set->packets[set->count].data = data;
        set->packets[set->count].size = size;
        set->count++;
    }

    rc = 0;

done:
    fclose(in);
    int status = 0;
    waitpid(pid, &status, 0);
    if (rc == 0 && !(WIFEXITED(status) && WEXITSTATUS(status) == 0)) {
        fprintf(stderr, "extractor process exited with an error\n");
        rc = -1;
    }
    return rc;
}

static void free_packets(PacketSet *set) {
    for (size_t i = 0; i < set->count; i++) {
        free(set->packets[i].data);
    }
    free(set->packets);
    set->packets = NULL;
    set->count = 0;
}

#endif /* PACKET_SOURCE_H */
