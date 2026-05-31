const std = @import("std");

const gpa = std.heap.wasm_allocator;

extern fn externPrint(offset: usize, length: usize) void;
extern fn consoleTime() void;
extern fn consoleTimeEnd() void;

var print_buffer: [1 << 16]u8 = undefined;

pub fn print(comptime string: []const u8, arguments: anytype) void {
    const message = std.fmt.bufPrint(&print_buffer, string, arguments) catch |err| switch (err) {
        error.NoSpaceLeft => &print_buffer, // Just print the entire buffer
    };

    externPrint(@intFromPtr(message.ptr), message.len);
}

pub fn printValues(arguments: anytype) void {
    if (false) {
        print("{}", .{arguments});
    }
}

const dc_code_params = [_]u8{ 0x04, 0x28, 0x28, 0x4D, 0x4D, 0x70, 0x70 };
const run_to_cb = [_]u8{ 0x06, 0x06, 0x05, 0x05, 0x04, 0x29, 0x29, 0x29, 0x29, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x4C };
const lev_to_cb = [_]u8{ 0x04, 0x0A, 0x05, 0x06, 0x04, 0x28, 0x28, 0x28, 0x28, 0x4C };

const scan_order = [_]u8{
    0,  1,  8,  9,  2,  3,  10, 11,
    16, 17, 24, 25, 18, 19, 26, 27,
    4,  5,  12, 20, 13, 6,  7,  14,
    21, 28, 29, 22, 15, 23, 30, 31,
    32, 33, 40, 48, 41, 34, 35, 42,
    49, 56, 57, 50, 43, 36, 37, 44,
    51, 58, 59, 52, 45, 38, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

const Decoder = struct {
    packet: []u8,
    slice_sizes: []u16,
    slice_data: []i32,
    frame_data: []f32,
    coded_width: u32,
    coded_height: u32,
    display_width: u32,
    display_height: u32,
};

export fn createDecoder() *Decoder {
    const result = gpa.create(Decoder) catch unreachable;
    result.* = .{
        .packet = &.{},
        .slice_sizes = &.{},
        .slice_data = &.{},
        .frame_data = &.{},
        .coded_width = undefined,
        .coded_height = undefined,
        .display_width = undefined,
        .display_height = undefined,
    };

    return result;
}

export fn getDisplayWidth(decoder: *Decoder) u32 {
    return decoder.display_width;
}

export fn getDisplayHeight(decoder: *Decoder) u32 {
    return decoder.display_height;
}

export fn getCodedWidth(decoder: *Decoder) u32 {
    return decoder.coded_width;
}

export fn getCodedHeight(decoder: *Decoder) u32 {
    return decoder.coded_height;
}

export fn getFrameDataPtr(decoder: *Decoder) [*]f32 {
    return decoder.frame_data.ptr;
}

export fn allocatePacket(decoder: *Decoder, size: usize) [*]u8 {
    decoder.packet = gpa.realloc(decoder.packet, size) catch unreachable;
    return decoder.packet.ptr;
}

export fn decodePacket(decoder: *Decoder) i32 {
    decodePacketInternal(decoder) catch return -1;

    return 0;
}

fn parseDc(decoder: *Decoder, bit_reader: *BitReader, num_luma_blocks: u32) void {
    bit_reader.maybeLoadData();

    const first_code_result = parseCode(bit_reader.current, 0xb8);
    var code: i32 = @intCast(first_code_result.value);

    const first_dc = (code >> 1) ^ -(code & 1);

    decoder.slice_data[0] = first_dc;

    var prev_dc = first_dc;

    const second_code_result = parseCode(
        bit_reader.current << @as(u6, @intCast(first_code_result.bits)),
        0x70,
    );
    code = @intCast(second_code_result.value);
    var sign: i32 = @intFromBool(code > 0) * -(code & 1); // else 0;

    const result = prev_dc + (((code + 1) >> 1) ^ sign) - sign;
    decoder.slice_data[64] = result;
    prev_dc = result;

    bit_reader.consume(@intCast(first_code_result.bits + second_code_result.bits));

    var j: usize = 2;
    while (j < num_luma_blocks) {
        bit_reader.maybeLoadData();

        const code_result_1 = parseCode(bit_reader.current, dc_code_params[@min(@as(usize, @intCast(code)), 6)]);

        code = @intCast(code_result_1.value);
        sign = @intFromBool(code > 0) * (sign ^ -(code & 1)); // else 0

        const result_1 = prev_dc + (((code + 1) >> 1) ^ sign) - sign;
        decoder.slice_data[64 * j] = result_1;

        const code_result_2 = parseCode(
            bit_reader.current << @as(u6, @intCast(code_result_1.bits)),
            dc_code_params[@min(code_result_1.value, 6)],
        );

        code = @intCast(code_result_2.value);
        sign = @intFromBool(code > 0) * (sign ^ -(code & 1)); // else 0

        const result_2 = result_1 + (((code + 1) >> 1) ^ sign) - sign;

        decoder.slice_data[64 * j + 64] = result_2;
        prev_dc = result_2;

        j += 2;
        bit_reader.consume(@intCast(code_result_1.bits + code_result_2.bits));
    }
}

fn parseAc(decoder: *Decoder, bit_reader: *BitReader, num_luma_blocks: u32) void {
    var run: u32 = 4;
    var level: i32 = 2;

    const log2_block_count = std.math.log2_int(u32, num_luma_blocks);
    const max_coeffs = @as(u32, 64) << log2_block_count;
    _ = max_coeffs;

    const block_mask = num_luma_blocks - 1;
    var pos = block_mask;

    while (true) {
        bit_reader.maybeLoadData();

        if (bit_reader.current == 0) {
            break;
        }

        const run_result = parseCode(bit_reader.current, run_to_cb[@min(run, 15)]);

        run = run_result.value;
        pos += run + 1;

        const level_result = parseCode(bit_reader.current << @as(u6, @intCast(run_result.bits)), lev_to_cb[@min(@as(u32, @intCast(level)), 9)]);
        level = @intCast(level_result.value);
        level += 1;

        const j = pos >> log2_block_count;
        const thing = run_result.bits + level_result.bits + 1;

        const sign = -@as(i32, @intCast((bit_reader.current >> @as(u6, @intCast(64 - thing))) & 1));

        bit_reader.consume(@intCast(thing));

        decoder.slice_data[((pos & block_mask) << 6) + scan_order[j]] = (level ^ sign) - sign;
    }
}

fn decodePacketInternal(decoder: *Decoder) !void {
    var reader = ByteReader.init(decoder.packet);

    const frame_size = reader.takeInt(u32);
    const frame_type_outer = reader.takeInt(u32);

    const hdr_size = reader.takeInt(u16);
    const version = reader.takeInt(u16);
    const creator_id = reader.takeInt(u32);
    const frame_width = reader.takeInt(u16);
    const frame_height = reader.takeInt(u16);
    const frame_flags = reader.takeInt(u8);
    const chrominance_factor = frame_flags >> 6;
    const frame_type = (frame_flags >> 2) & 0b11;
    reader.toss(1);
    const primaries = reader.takeInt(u8);
    const transfer_function = reader.takeInt(u8);
    const color_matrix = reader.takeInt(u8);
    const next_byte = reader.takeInt(u8);
    const src_pix_format = next_byte >> 4;
    const alpha_info = next_byte & 0b1111;
    reader.toss(1);
    const q_mat_flags = reader.takeInt(u8);

    const q_mat_luma: [64]u8 = if (q_mat_flags & 0b10 != 0)
        reader.takeArray(64).*
    else
        @splat(4);

    const q_mat_chroma: [64]u8 = if (q_mat_flags & 0b01 != 0)
        reader.takeArray(64).*
    else
        @splat(4);

    printValues(.{ frame_size, frame_type_outer, hdr_size, version, creator_id, frame_width, frame_height, frame_flags, chrominance_factor, frame_type, primaries, transfer_function, color_matrix, src_pix_format, alpha_info, q_mat_flags, q_mat_luma, q_mat_chroma });

    decoder.display_width = frame_width;
    decoder.display_height = frame_height;
    decoder.coded_width = (frame_width + 15) & ~@as(u32, 15);
    decoder.coded_height = (frame_height + 15) & ~@as(u32, 15);

    decoder.frame_data = try gpa.realloc(decoder.frame_data, decoder.coded_width * decoder.coded_height);

    const pic_hdr_size = reader.takeInt(u8);
    const pic_data_size = reader.takeInt(u32);
    const total_slices = reader.takeInt(u16);
    const slice_dimensions = reader.takeInt(u8);
    const slice_width = @as(u32, 1) << @as(u5, @intCast(slice_dimensions >> 4));
    const slice_height = @as(u32, 1) << @as(u5, @intCast(slice_dimensions & 0b1111));

    decoder.slice_sizes = try gpa.realloc(decoder.slice_sizes, total_slices);
    for (0..total_slices) |i| {
        decoder.slice_sizes[i] = reader.takeInt(u16);
    }

    const num_luma_blocks = 4 * slice_width * slice_height;

    decoder.slice_data = try gpa.realloc(decoder.slice_data, 64 * num_luma_blocks);

    printValues(.{ pic_hdr_size, pic_data_size, total_slices, slice_dimensions, slice_width, slice_height, decoder.slice_sizes });

    var slice_x: u32 = 0;
    var slice_y: u32 = 0;

    for (0..total_slices) |i| {
        const slice_start_pos = reader.pos;
        const slice_size = decoder.slice_sizes[i];
        const slice_hdr_size = reader.takeInt(u8);

        var scale_factor = reader.takeInt(u8);
        if (scale_factor > 128) {
            scale_factor = (scale_factor - 96) << 2;
        }

        const luma_data_size = reader.takeInt(u16);
        const u_data_size = reader.takeInt(u16);
        const v_data_size = slice_size - luma_data_size - u_data_size - @divExact(slice_hdr_size, 8);

        _ = v_data_size;

        @memset(decoder.slice_data, 0);

        const ac_data = reader.take(luma_data_size);
        var bit_reader = BitReader.fromData(ac_data);

        parseDc(decoder, &bit_reader, num_luma_blocks);

        parseAc(decoder, &bit_reader, num_luma_blocks);

        if (false) {
            for (0..num_luma_blocks) |j| {
                const block_offset_x = 16 * (j / 4) + 8 * (j % 2);
                const block_offset_y: u32 = if (j % 4 < 2) 0 else 8;
                const block_x = slice_x + block_offset_x;
                const block_y = slice_y + block_offset_y;
                const block = decoder.slice_data[64 * j ..][0..64];

                var mh: [64]f32 = undefined;

                for (0..64) |k| {
                    const value = if (k == 0)
                        4096 + ((block[k] * q_mat_luma[k] * scale_factor) >> 2)
                    else
                        (block[k] * q_mat_luma[k] * scale_factor) >> 2;

                    mh[k] = @floatFromInt(value);
                }

                idct8x8(&mh);

                for (0..8) |x| {
                    for (0..8) |y| {
                        decoder.frame_data[decoder.coded_width * (block_y + y) + block_x + x] = mh[y * 8 + x] / 1024;
                    }
                }
            }
        }

        reader.pos = slice_start_pos + slice_size;

        slice_x += 16 * slice_width;

        if (slice_x >= decoder.coded_width) {
            slice_x = 0;
            slice_y += 16 * slice_height;
        }
    }
}

const S = [_]f32{
    0.353553390593273762200422,
    0.254897789552079584470970,
    0.270598050073098492199862,
    0.300672443467522640271861,
    0.353553390593273762200422,
    0.449988111568207852319255,
    0.653281482438188263928322,
    1.281457723870753089398043,
};

const A = [_]f32{
    std.math.nan(f32),
    0.707106781186547524400844,
    0.541196100146196984399723,
    0.707106781186547524400844,
    1.306562964876376527856643,
    0.382683432365089771728460,
};

inline fn idct8(vector: *[8]f32) void {
    const v15 = vector[0] / S[0];
    const v26 = vector[1] / S[1];
    const v21 = vector[2] / S[2];
    const v28 = vector[3] / S[3];
    const v16 = vector[4] / S[4];
    const v25 = vector[5] / S[5];
    const v22 = vector[6] / S[6];
    const v27 = vector[7] / S[7];

    const v19 = (v25 - v28) / 2;
    const v20 = (v26 - v27) / 2;
    const v23 = (v26 + v27) / 2;
    const v24 = (v25 + v28) / 2;

    const v7 = (v23 + v24) / 2;
    const v11 = (v21 + v22) / 2;
    const v13 = (v23 - v24) / 2;
    const v17 = (v21 - v22) / 2;

    const v8 = (v15 + v16) / 2;
    const v9 = (v15 - v16) / 2;

    const v18 = (v19 - v20) * A[5]; // Different from original
    const v12 = (v19 * A[4] - v18) / (A[2] * A[5] - A[2] * A[4] - A[4] * A[5]);
    const v14 = (v18 - v20 * A[2]) / (A[2] * A[5] - A[2] * A[4] - A[4] * A[5]);

    const v6 = v14 - v7;
    const v5 = v13 / A[3] - v6;
    const v4 = -v5 - v12;
    const v10 = v17 / A[1] - v11;

    const v0 = (v8 + v11) / 2;
    const v1 = (v9 + v10) / 2;
    const v2 = (v9 - v10) / 2;
    const v3 = (v8 - v11) / 2;

    vector[0] = (v0 + v7) / 2;
    vector[1] = (v1 + v6) / 2;
    vector[2] = (v2 + v5) / 2;
    vector[3] = (v3 + v4) / 2;
    vector[4] = (v3 - v4) / 2;
    vector[5] = (v2 - v5) / 2;
    vector[6] = (v1 - v6) / 2;
    vector[7] = (v0 - v7) / 2;
}

fn idct8x8(block: *[64]f32) void {
    inline for (0..8) |row| {
        idct8(block[8 * row ..][0..8]);
    }

    inline for (0..8) |column| {
        var temp: [8]f32 = undefined;
        temp[0] = block[0 * 8 + column];
        temp[1] = block[1 * 8 + column];
        temp[2] = block[2 * 8 + column];
        temp[3] = block[3 * 8 + column];
        temp[4] = block[4 * 8 + column];
        temp[5] = block[5 * 8 + column];
        temp[6] = block[6 * 8 + column];
        temp[7] = block[7 * 8 + column];

        idct8(&temp);

        block[0 * 8 + column] = temp[0];
        block[1 * 8 + column] = temp[1];
        block[2 * 8 + column] = temp[2];
        block[3 * 8 + column] = temp[3];
        block[4 * 8 + column] = temp[4];
        block[5 * 8 + column] = temp[5];
        block[6 * 8 + column] = temp[6];
        block[7 * 8 + column] = temp[7];
    }
}

const ByteReader = struct {
    data: []u8,
    pos: usize,

    fn init(data: []u8) ByteReader {
        return .{
            .data = data,
            .pos = 0,
        };
    }

    inline fn takeInt(self: *ByteReader, comptime T: type) T {
        if (T == u8) {
            const value = self.data[self.pos];
            self.pos += 1;

            return value;
        }

        const size = @divExact(@typeInfo(T).int.bits, 8);
        const value = std.mem.readInt(T, self.data[self.pos..][0..size], .big);
        self.pos += size;

        return value;
    }

    inline fn takeArray(self: *ByteReader, comptime n: usize) *[n]u8 {
        const arr = self.data[self.pos..][0..n];
        self.pos += n;
        return arr;
    }

    inline fn take(self: *ByteReader, n: usize) []u8 {
        const slice = self.data[self.pos..][0..n];
        self.pos += n;
        return slice;
    }

    inline fn toss(self: *ByteReader, n: usize) void {
        self.pos += n;
    }

    inline fn remaining(self: *const ByteReader) usize {
        return self.data.len - self.pos;
    }
};

const ParsedCode = struct {
    value: u32,
    bits: u32,
};

inline fn parseCode(word: u64, params: u8) ParsedCode {
    const mp: u32 = params & 0b11;
    const g: u32 = (params >> 2) & 0b111;
    const r: u32 = params >> 5;

    const n: u32 = @clz(word);
    const is_big = n > mp;

    const base = @as(u32, @min(n, mp + 1)) << @as(u5, @intCast(r));

    const bits_big = 2 *% n +% g -% mp;
    const bits_small = n + 1 + r;
    const bits = if (is_big) bits_big else bits_small;
    const sub = @as(u32, 1) << (if (is_big) @intCast(g) else @intCast(r));
    const raw: u32 = @intCast(word >> @as(u6, @intCast(64 - bits)));

    const result = base +% raw -% sub;

    return .{
        .value = result,
        .bits = bits,
    };
}

const BitReader = struct {
    reader: ByteReader,
    current: u64,
    next: u64,
    bit_health: u8,

    fn fromData(data: []u8) BitReader {
        return .{
            .reader = ByteReader.init(data),
            .current = 0,
            .next = 0,
            .bit_health = 0,
        };
    }

    inline fn maybeLoadData(self: *BitReader) void {
        if (self.bit_health >= 64) {
            return;
        }

        std.debug.assert(self.next == 0);

        const remaining = self.reader.remaining();

        if (remaining < 8) {
            @branchHint(.unlikely);

            switch (remaining) {
                0 => {},
                inline 1...7 => |remaining_captured| {
                    const int_type = @Int(.unsigned, remaining_captured << 3);
                    var next_word: u64 = self.reader.takeInt(int_type);
                    next_word <<= (8 - remaining_captured) << 3;

                    self.current |= next_word >> @as(u6, @intCast(self.bit_health));

                    self.next = if (self.bit_health != 0)
                        next_word << @as(u6, @intCast(64 - self.bit_health))
                    else
                        0;

                    self.bit_health += @intCast(remaining_captured << 3);
                },
                else => unreachable,
            }
        } else {
            const next_word: u64 = self.reader.takeInt(u64);

            self.current |= next_word >> @as(u6, @intCast(self.bit_health));

            self.next = if (self.bit_health != 0)
                next_word << @as(u6, @intCast(64 - self.bit_health))
            else
                0;

            self.bit_health += 64;
        }
    }

    inline fn consume(self: *BitReader, bits: u8) void {
        self.current <<= @as(u6, @intCast(bits));
        self.current |= self.next >> @as(u6, @intCast(64 - bits));
        self.next <<= @as(u6, @intCast(bits));
        self.bit_health -= bits;
    }
};
