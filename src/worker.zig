// Copyright (c) 2026-present, Vanilagy and contributors
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const misc = @import("./misc.zig");
const gpa = misc.gpa;
const DecodeTask = @import("./decoder.zig").DecodeTask;
const executeDecodeTask = @import("./decoder.zig").executeDecodeTask;

export fn allocateWorkerStack() ?[*]u8 {
    // 512 KiB per worker should be plenty
    const stack = gpa.alloc(u8, 512 * 1024) catch return null;
    // The WASM stack grows downward, so the stack pointer must start at the TOP of the buffer
    return stack.ptr + stack.len;
}

export fn allocateThreadLocalState(size: usize, alignment: u8) ?[*]u8 {
    // Use wasm_allocator instead of gpa here because gpa requires thread-local state
    return misc.wasm_allocator.rawAlloc(size, .fromByteUnits(alignment), @returnAddress());
}

const WorkerTask = union(enum) {
    decode: *DecodeTask,
};

pub const WorkerError = struct {
    code: i32,
    message: ?[]const u8,
};

pub var worker_task_queue = std.Deque(WorkerTask).empty;
pub var worker_task_queue_mutex = std.Io.Mutex.init;

// A u32 mirror of `worker_task_queue.len`, kept in sync under `worker_task_queue_mutex`. We futex on this rather than
// on the deque's `len` field directly because that field is a `usize` (8 bytes on 64-bit native targets), but futex
// words must be exactly 32 bits wide.
pub var work_signal = std.atomic.Value(u32).init(0);

// Preallocated on the stack so that allocation of it can't fail
threadlocal var worker_error: WorkerError = undefined;

export fn startWorker() noreturn {
    while (true) {
        misc.io.futexWait(u32, &work_signal.raw, 0) catch unreachable; // Can't cancel here

        var task: WorkerTask = undefined;
        {
            misc.lockMutex(&worker_task_queue_mutex);
            defer worker_task_queue_mutex.unlock(misc.io);

            if (worker_task_queue.len == 0) {
                continue;
            }

            task = worker_task_queue.popFront().?;
            work_signal.store(@intCast(worker_task_queue.len), .seq_cst);
        }

        switch (task) {
            .decode => |decode_task| {
                const decoder = decode_task.decoder;

                executeDecodeTask(decode_task) catch |err| {
                    worker_error = .{
                        .code = misc.toErrorCode(err),
                        .message = decode_task.error_message,
                    };

                    _ = decoder.worker_error.cmpxchgStrong(
                        null,
                        &worker_error,
                        .seq_cst,
                        .seq_cst,
                    );
                };

                if (decoder.running_task_count.fetchSub(1, .seq_cst) == 1) {
                    decoder.task_state.store(.done, .seq_cst);
                    misc.io.futexWake(u32, @ptrCast(&decoder.task_state.raw), std.math.maxInt(i32));
                }
            },
        }
    }
}

// Native targets spawn their own worker threads (on WASM, the host spawns them and calls `startWorker`).
var pool_lock = std.atomic.Value(bool).init(false);
var spawned_worker_count: u32 = 0;

/// Ensures at least `count` worker threads are running. No-op on WASM, where the host (JS) owns thread creation.
pub fn ensureWorkers(count: u32) !void {
    if (misc.is_wasm) {
        return;
    } else {
        while (pool_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
        defer pool_lock.store(false, .release);

        while (spawned_worker_count < count) {
            const thread = try std.Thread.spawn(.{}, workerThreadMain, .{});
            thread.detach();
            spawned_worker_count += 1;
        }
    }
}

fn workerThreadMain() void {
    startWorker();
}
