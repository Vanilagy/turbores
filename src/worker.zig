const std = @import("std");
const misc = @import("./misc.zig");
const gpa = misc.gpa;
const io = misc.io;
const DecodeTask = @import("./decoder.zig").DecodeTask;
const executeDecodeTask = @import("./decoder.zig").executeDecodeTask;

export fn allocateWorkerStack() ?[*]u8 {
    // 512 KiB per worker should be plenty
    const stack = gpa.alloc(u8, 512 * 1024) catch return null;
    return stack.ptr;
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

pub var num_workers = std.atomic.Value(u32).init(0);
pub var worker_task_queue = std.Deque(WorkerTask).empty;
pub var worker_task_queue_mutex = std.Io.Mutex.init;

// Preallocated on the stack so that allocation of it can't fail
threadlocal var worker_error: WorkerError = undefined;

export fn startWorker() noreturn {
    _ = num_workers.fetchAdd(1, .seq_cst);

    while (true) {
        io.futexWait(u32, &worker_task_queue.len, 0) catch unreachable; // Can't cancel in WASM

        var task: WorkerTask = undefined;
        {
            misc.lockMutex(&worker_task_queue_mutex);
            defer worker_task_queue_mutex.unlock(io);

            if (worker_task_queue.len == 0) {
                continue;
            }

            task = worker_task_queue.popFront().?;
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
                    io.futexWake(u32, &decoder.wait_word, 4);
                }
            },
        }
    }
}
