const std = @import("std");
const misc = @import("./misc.zig");
const gpa = misc.gpa;
const io = misc.io;
const Decoder = @import("./decoder.zig").Decoder;
const executeDecodeTask = @import("./decoder.zig").executeDecodeTask;

export fn allocateWorkerStack() [*]u8 {
    // 512 KiB per worker should be plenty
    const stack = gpa.alloc(u8, 512 * 1024) catch unreachable;
    return stack.ptr;
}

export fn allocateThreadLocalState(size: usize, alignment: u8) [*]u8 {
    // Use wasm_allocator instead of gpa here because gpa requires thread-local state
    const result = misc.wasm_allocator.rawAlloc(size, .fromByteUnits(alignment), @returnAddress());
    return result.?;
}

pub const WorkerDecodeTask = struct {
    decoder: *Decoder,
    slice_start: usize,
    slice_count: usize,
};

const WorkerTask = union(enum) {
    decode: *WorkerDecodeTask,
};

pub var num_workers = std.atomic.Value(u32).init(0);
pub var worker_task_queue = std.Deque(WorkerTask).empty;
pub var worker_task_queue_mutex = std.Io.Mutex.init;

export fn startWorker() noreturn {
    _ = num_workers.fetchAdd(1, .monotonic);

    while (true) {
        io.futexWait(u32, &worker_task_queue.len, 0) catch unreachable;

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
                executeDecodeTask(decode_task) catch unreachable; // Temp
            },
        }
    }
}
