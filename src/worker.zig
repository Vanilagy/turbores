// Copyright (c) 2026-present, Vanilagy and contributors
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const misc = @import("./misc.zig");
const gpa = misc.gpa;
const io = misc.io;
const DecodeTask = @import("./decoder.zig").DecodeTask;
const executeDecodeTask = @import("./decoder.zig").executeDecodeTask;

pub fn allocateWorkerStack() callconv(.c) ?[*]u8 {
    // 512 KiB per worker should be plenty
    const stack = gpa.alloc(u8, 512 * 1024) catch return null;
    // The WASM stack grows downward, so the stack pointer must start at the TOP of the buffer
    return stack.ptr + stack.len;
}

pub fn allocateThreadLocalState(size: usize, alignment: u8) callconv(.c) ?[*]u8 {
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
// Atomic mirror of worker_task_queue.len, updated under the mutex
pub var worker_task_queue_len = std.atomic.Value(u32).init(0);

var pool_mutex = std.Io.Mutex.init;
var pool_thread_count: u32 = 0;

// Natively, the library manages its own thread pool. It is shared across all decoders and grows to the largest
// concurrency requested so far.
pub fn ensureThreads(count: u32) !void {
    misc.lockMutex(&pool_mutex);
    defer pool_mutex.unlock(io);

    while (pool_thread_count < count) : (pool_thread_count += 1) {
        const thread = try std.Thread.spawn(.{}, workerLoop, .{});
        thread.detach();
    }
}

// Preallocated on the stack so that allocation of it can't fail
threadlocal var worker_error: WorkerError = undefined;

pub fn startWorker() callconv(.c) noreturn {
    workerLoop();
}

fn workerLoop() noreturn {
    while (true) {
        io.futexWait(u32, &worker_task_queue_len.raw, 0) catch unreachable; // Won't be canceled

        var task: WorkerTask = undefined;
        {
            misc.lockMutex(&worker_task_queue_mutex);
            defer worker_task_queue_mutex.unlock(io);

            if (worker_task_queue.len == 0) {
                continue;
            }

            task = worker_task_queue.popFront().?;
            worker_task_queue_len.store(@intCast(worker_task_queue.len), .monotonic);
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
                    io.futexWake(u32, @ptrCast(&decoder.task_state.raw), std.math.maxInt(i32));
                }
            },
        }
    }
}
