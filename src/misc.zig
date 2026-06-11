// Copyright (c) 2026-present, Vanilagy and contributors
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const builtin = @import("builtin");
const BrkAllocator = @import("./BrkAllocator.zig");

extern fn externPrint(offset: usize, length: usize) void;

pub threadlocal var is_browser_main_thread: bool = undefined;

export fn setIsBrowserMainThread(value: u32) void {
    is_browser_main_thread = value != 0;
}

pub fn print(comptime string: []const u8, arguments: anytype) void {
    var print_buffer: [1 << 16]u8 = undefined;

    const message = std.fmt.bufPrint(&print_buffer, string, arguments) catch |err| switch (err) {
        error.NoSpaceLeft => &print_buffer, // Just print the entire buffer
    };

    externPrint(@intFromPtr(message.ptr), message.len);
}

pub fn printValues(arguments: anytype) void {
    if (true) {
        print("{}", .{arguments});
    }
}

pub const io = blk: {
    var vtable = std.Io.failing.vtable.*;
    vtable.futexWait = &futexWait;
    vtable.futexWake = &futexWake;
    const vtable_const = vtable;

    break :blk std.Io{
        .userdata = null,
        .vtable = &vtable_const,
    };
};

var gpa_mutex = std.Io.Mutex.init;
pub const wasm_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &BrkAllocator.vtable,
};
pub const gpa: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = &alloc,
        .resize = &resize,
        .remap = &remap,
        .free = &free,
    },
};

fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    lockMutex(&gpa_mutex);
    defer gpa_mutex.unlock(io);

    return wasm_allocator.vtable.alloc(ptr, len, alignment, ret_addr);
}

fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    lockMutex(&gpa_mutex);
    defer gpa_mutex.unlock(io);

    return wasm_allocator.vtable.resize(ptr, memory, alignment, new_len, ret_addr);
}

fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    lockMutex(&gpa_mutex);
    defer gpa_mutex.unlock(io);

    return wasm_allocator.vtable.remap(ptr, memory, alignment, new_len, ret_addr);
}

fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    lockMutex(&gpa_mutex);
    defer gpa_mutex.unlock(io);

    wasm_allocator.vtable.free(ptr, memory, alignment, ret_addr);
}

fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    _ = userdata;

    const timeout_ns: ?u64 = ns: {
        const d = timeout.toDurationFromNow(io) orelse break :ns null;
        break :ns std.math.lossyCast(u64, d.raw.toNanoseconds());
    };

    const is_debug = builtin.mode == .Debug;

    comptime std.debug.assert(builtin.cpu.has(.wasm, .atomics));
    const to: i64 = if (timeout_ns) |ns| std.math.cast(i64, ns) orelse std.math.maxInt(i64) else -1;
    const signed_expect: i32 = @bitCast(expected);
    const result = asm volatile (
        \\local.get %[ptr]
        \\local.get %[expected]
        \\local.get %[timeout]
        \\memory.atomic.wait32 0
        \\local.set %[ret]
        : [ret] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [expected] "r" (signed_expect),
          [timeout] "r" (to),
    );
    switch (result) {
        0 => {}, // ok
        1 => {}, // expected != loaded
        2 => {}, // timeout
        else => std.debug.assert(!is_debug),
    }
}

fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    @branchHint(.cold);
    std.debug.assert(max_waiters != 0);

    _ = userdata;

    comptime std.debug.assert(builtin.cpu.has(.wasm, .atomics));
    const woken_count = asm volatile (
        \\local.get %[ptr]
        \\local.get %[waiters]
        \\memory.atomic.notify 0
        \\local.set %[ret]
        : [ret] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [waiters] "r" (max_waiters),
    );
    _ = woken_count; // can be 0 when linker flag 'shared-memory' is not enabled
}

pub inline fn lockMutex(mutex: *std.Io.Mutex) void {
    if (is_browser_main_thread) {
        // The browser main thread isn't allowed to block on atomics.wait, so the best we can do is a spinlock
        while (!mutex.tryLock()) {}
    } else {
        mutex.lock(io) catch unreachable; // Cancels can't happen in WASM
    }
}

pub const ConvertibleError = error{
    OutOfMemory,
    UnexpectedEof,
    InvalidData,
    NotSupported,
    InvalidState,
    Overflow,
};

pub inline fn toErrorCode(err: ConvertibleError) i32 {
    return switch (err) {
        error.OutOfMemory => -1,
        error.UnexpectedEof => -2,
        error.InvalidData => -3,
        error.NotSupported => -4,
        error.InvalidState => -5,
        error.Overflow => -6,
    };
}

pub const ByteReader = struct {
    data: []u8,
    pos: usize,

    pub fn init(data: []u8) ByteReader {
        return .{
            .data = data,
            .pos = 0,
        };
    }

    pub inline fn takeInt(self: *ByteReader, comptime T: type) !T {
        const size = @divExact(@typeInfo(T).int.bits, 8);

        if (size > self.remaining()) {
            return error.UnexpectedEof;
        }

        return self.takeIntUnchecked(T);
    }

    pub inline fn takeIntUnchecked(self: *ByteReader, comptime T: type) T {
        const size = @divExact(@typeInfo(T).int.bits, 8);

        std.debug.assert(size <= self.remaining());

        if (T == u8) {
            const value = self.data[self.pos];
            self.pos += 1;

            return value;
        }

        const value = std.mem.readInt(T, self.data[self.pos..][0..size], .big);
        self.pos += size;

        return value;
    }

    pub inline fn takeArray(self: *ByteReader, comptime n: usize) !*[n]u8 {
        if (n > self.remaining()) {
            return error.UnexpectedEof;
        }

        const arr = self.data[self.pos..][0..n];
        self.pos += n;
        return arr;
    }

    pub inline fn take(self: *ByteReader, n: usize) ![]u8 {
        if (n > self.remaining()) {
            return error.UnexpectedEof;
        }

        return self.takeUnchecked(n);
    }

    pub inline fn takeUnchecked(self: *ByteReader, n: usize) []u8 {
        std.debug.assert(n <= self.remaining());

        const slice = self.data[self.pos..][0..n];
        self.pos += n;
        return slice;
    }

    pub inline fn toss(self: *ByteReader, n: usize) void {
        self.pos += n;
    }

    pub inline fn remaining(self: *const ByteReader) usize {
        return self.data.len - self.pos;
    }
};

pub const BitReader = struct {
    reader: ByteReader,
    current: u64,
    next: u64,
    bit_health: u64,

    pub inline fn fromData(data: []u8) BitReader {
        return .{
            .reader = ByteReader.init(data),
            .current = 0,
            .next = 0,
            .bit_health = 0,
        };
    }

    pub inline fn maybeLoadData(self: *BitReader) void {
        if (self.bit_health >= 64) {
            @branchHint(.likely);
            return;
        }

        std.debug.assert(self.next == 0);

        const remaining = self.reader.remaining();

        if (remaining < 8) {
            @branchHint(.unlikely);

            var next_word: u64 = undefined;

            // This version is faster than a generic for loop that reads bytes
            switch (remaining) {
                0 => {
                    next_word = 0;
                },
                inline 1...7 => |remaining_captured| {
                    const int_type = @Int(.unsigned, remaining_captured << 3);
                    next_word = self.reader.takeIntUnchecked(int_type);
                    next_word <<= (8 - remaining_captured) << 3;
                },
                else => unreachable,
            }

            self.current |= next_word >> @as(u6, @intCast(self.bit_health));

            self.next = if (self.bit_health != 0)
                next_word << @as(u6, @intCast(64 - self.bit_health))
            else
                0;

            self.bit_health = comptime std.math.maxInt(u64); // So that the load never runs again
        } else {
            const next_word: u64 = self.reader.takeIntUnchecked(u64);

            self.current |= next_word >> @as(u6, @intCast(self.bit_health));

            self.next = if (self.bit_health != 0)
                next_word << @as(u6, @intCast(64 - self.bit_health))
            else
                0;

            self.bit_health += 64;
        }
    }

    pub inline fn consume(self: *BitReader, bits: u64) void {
        self.current <<= @as(u6, @intCast(bits));
        self.current |= self.next >> @as(u6, @intCast(64 - bits));
        self.next <<= @as(u6, @intCast(bits));
        self.bit_health -= bits;
    }
};
