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

// Overall reference: https://wiki.multimedia.cx/index.php/Apple_ProRes

const scan_order = transpose_scan_values(.{
    0,  1,  8,  9,  2,  3,  10, 11,
    16, 17, 24, 25, 18, 19, 26, 27,
    4,  5,  12, 20, 13, 6,  7,  14,
    21, 28, 29, 22, 15, 23, 30, 31,
    32, 33, 40, 48, 41, 34, 35, 42,
    49, 56, 57, 50, 43, 36, 37, 44,
    51, 58, 59, 52, 45, 38, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
});

const run_to_cb = [_]u8{ 0x06, 0x06, 0x05, 0x05, 0x04, 0x29, 0x29, 0x29, 0x29, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x4C };
const lev_to_cb = [_]u8{ 0x04, 0x0A, 0x05, 0x06, 0x04, 0x28, 0x28, 0x28, 0x28, 0x4C };
const dc_code_params = [_]u8{ 0x04, 0x28, 0x28, 0x4D, 0x4D, 0x70, 0x70 };

fn transpose_scan_values(s: [64]u8) [64]u8 {
    var result: [64]u8 = undefined;

    for (s, 0..) |pos, i| {
        result[i] = 8 * (pos % 8) + (pos / 8);
    }

    return result;
}

inline fn transpose_8x8(Element: type, matrix: [64]Element) [64]Element {
    var result: [64]Element = undefined;

    inline for (0..8) |x| {
        inline for (0..8) |y| {
            result[8 * y + x] = matrix[8 * x + y];
        }
    }

    return result;
}

const Decoder = struct {
    packet: []u8,
    frame_data: []u16,
    coded_width: u32,
    coded_height: u32,
    display_width: u32,
    display_height: u32,
};

export fn createDecoder() *Decoder {
    const result = gpa.create(Decoder) catch unreachable;
    result.* = .{
        .packet = &.{},
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

export fn getFrameDataPtr(decoder: *Decoder) [*]u16 {
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

const SliceHeader = struct {
    scale_factor: u32,
    luma_bit_reader: BitReader,
    u_bit_reader: BitReader,
    v_bit_reader: BitReader,
};

inline fn parseSliceHeader(slice_sizes: []u16, reader: *ByteReader, i: usize) SliceHeader {
    const slice_size = slice_sizes[i];
    const slice_hdr_size = reader.takeInt(u8);

    var scale_factor: u32 = reader.takeInt(u8);
    if (scale_factor > 128) {
        scale_factor = (scale_factor - 96) << 2;
    }

    const luma_data_size = reader.takeInt(u16);
    const u_data_size = reader.takeInt(u16);
    const v_data_size = slice_size - luma_data_size - u_data_size - @divExact(slice_hdr_size, 8);

    const luma_data = reader.take(luma_data_size);
    const u_data = reader.take(u_data_size);
    const v_data = reader.take(v_data_size);

    return .{
        .scale_factor = scale_factor,
        .luma_bit_reader = BitReader.fromData(luma_data),
        .u_bit_reader = BitReader.fromData(u_data),
        .v_bit_reader = BitReader.fromData(v_data),
    };
}

const DcState = struct {
    bit_reader: *BitReader,
    slice_data: []f32,
    code: i32,
    sign: i32,
    prev_dc: i32,

    inline fn init(bit_reader: *BitReader, slice_data: []f32) DcState {
        var s = DcState{
            .bit_reader = bit_reader,
            .slice_data = slice_data,
            .code = undefined,
            .sign = undefined,
            .prev_dc = undefined,
        };

        s.bit_reader.maybeLoadData();

        const first_code_result = parseCode(s.bit_reader.current, 0xb8);
        s.code = @intCast(first_code_result.value);

        const first_dc = (s.code >> 1) ^ -(s.code & 1);
        s.slice_data[0] = @floatFromInt(first_dc);
        s.prev_dc = first_dc;

        const second_code_result = parseCode(
            s.bit_reader.current << @as(u6, @intCast(first_code_result.bits)),
            0x70,
        );
        s.code = @intCast(second_code_result.value);
        s.sign = @intFromBool(s.code > 0) * -(s.code & 1);

        const result = s.prev_dc + (((s.code + 1) >> 1) ^ s.sign) - s.sign;
        s.slice_data[64] = @floatFromInt(result);
        s.prev_dc = result;

        s.bit_reader.consume(@intCast(first_code_result.bits + second_code_result.bits));

        return s;
    }

    inline fn step(self: *DcState, j: usize) void {
        self.bit_reader.maybeLoadData();

        const code_result_1 = parseCode(self.bit_reader.current, dc_code_params[@min(@as(usize, @intCast(self.code)), 6)]);

        self.code = @intCast(code_result_1.value);
        self.sign = @intFromBool(self.code > 0) * (self.sign ^ -(self.code & 1));

        const result_1 = self.prev_dc + (((self.code + 1) >> 1) ^ self.sign) - self.sign;
        self.slice_data[64 * j] = @floatFromInt(result_1);

        const code_result_2 = parseCode(
            self.bit_reader.current << @as(u6, @intCast(code_result_1.bits)),
            dc_code_params[@min(code_result_1.value, 6)],
        );

        self.code = @intCast(code_result_2.value);
        self.sign = @intFromBool(self.code > 0) * (self.sign ^ -(self.code & 1));

        const result_2 = result_1 + (((self.code + 1) >> 1) ^ self.sign) - self.sign;
        self.slice_data[64 * j + 64] = @floatFromInt(result_2);
        self.prev_dc = result_2;

        self.bit_reader.consume(@intCast(code_result_1.bits + code_result_2.bits));
    }
};

const AcState = struct {
    bit_reader: *BitReader,
    slice_data: []f32,
    pos: u32,
    log2_block_count: u5,
    block_mask: u32,
    run: u32 = 4,
    level: i32 = 2,

    inline fn step(self: *AcState) bool {
        self.bit_reader.maybeLoadData();
        if (self.bit_reader.current == 0) {
            return false;
        }

        const run_result = parseCode(self.bit_reader.current, run_to_cb[@min(self.run, 15)]);
        self.run = run_result.value;
        self.pos += self.run + 1;

        const level_result = parseCode(
            self.bit_reader.current << @as(u6, @intCast(run_result.bits)),
            lev_to_cb[@min(@as(u32, @intCast(self.level)), 9)],
        );
        self.level = @as(i32, @intCast(level_result.value)) + 1;

        const j = self.pos >> self.log2_block_count;
        const thing = run_result.bits + level_result.bits + 1;
        const sign = -@as(i32, @intCast((self.bit_reader.current >> @as(u6, @intCast(64 - thing))) & 1));
        self.bit_reader.consume(@intCast(thing));
        self.slice_data[((self.pos & self.block_mask) << 6) + scan_order[j]] = @floatFromInt((self.level ^ sign) - sign);

        return true;
    }
};

fn parseDcPair(
    bit_reader_1: *BitReader,
    bit_reader_2: *BitReader,
    slice_1_data: []f32,
    slice_2_data: []f32,
    num_blocks: u32,
) void {
    var dc_state_1 = DcState.init(bit_reader_1, slice_1_data);
    var dc_state_2 = DcState.init(bit_reader_2, slice_2_data);

    var j: u32 = 2;
    while (j < num_blocks) : (j += 2) {
        dc_state_1.step(j);
        dc_state_2.step(j);
    }
}

fn parseAcPair(
    bit_reader_1: *BitReader,
    bit_reader_2: *BitReader,
    slice_1_data: []f32,
    slice_2_data: []f32,
    num_blocks: u32,
) void {
    const log2_block_count: u5 = @intCast(std.math.log2_int(u32, num_blocks));
    const block_mask = num_blocks - 1;

    var ac_state_1 = AcState{
        .bit_reader = bit_reader_1,
        .slice_data = slice_1_data,
        .pos = block_mask,
        .log2_block_count = log2_block_count,
        .block_mask = block_mask,
    };
    var ac_state_2 = AcState{
        .bit_reader = bit_reader_2,
        .slice_data = slice_2_data,
        .pos = block_mask,
        .log2_block_count = log2_block_count,
        .block_mask = block_mask,
    };

    var active_1 = true;
    var active_2 = true;
    while (active_1 and active_2) {
        active_1 = ac_state_1.step();
        active_2 = ac_state_2.step();
    }
    while (active_1) active_1 = ac_state_1.step();
    while (active_2) active_2 = ac_state_2.step();
}

fn parseDcSingle(bit_reader: *BitReader, slice_data: []f32, num_blocks: u32) void {
    var dc_state = DcState.init(bit_reader, slice_data);

    var j: u32 = 2;
    while (j < num_blocks) : (j += 2) {
        dc_state.step(j);
    }
}

fn parseAcSingle(bit_reader: *BitReader, slice_data: []f32, num_blocks: u32) void {
    const log2_block_count: u5 = @intCast(std.math.log2_int(u32, num_blocks));
    const block_mask = num_blocks - 1;

    var ac_state = AcState{
        .bit_reader = bit_reader,
        .slice_data = slice_data,
        .pos = block_mask,
        .log2_block_count = log2_block_count,
        .block_mask = block_mask,
    };

    while (ac_state.step()) {}
}

fn transformAndStoreSliceData(
    decoder: *Decoder,
    slice_data: []const f32,
    frame_data: []u16,
    scaling_matrix_vec: @Vector(64, f32),
    slice_pos: SlicePos,
    num_blocks: u32,
    comptime blocks_per_macroblock: u8,
) void {
    comptime std.debug.assert(blocks_per_macroblock == 2 or blocks_per_macroblock == 4);

    const coded_width = decoder.coded_width >> (if (blocks_per_macroblock == 2) 1 else 0);

    var j: u32 = 0;
    while (j < num_blocks) : (j += 2) {
        const block_a = slice_data[64 * j ..][0..64].*;
        const block_b = slice_data[64 * j + 64 ..][0..64].*;

        const result_a = idct_8x8(block_a, scaling_matrix_vec);
        const result_b = idct_8x8(block_b, scaling_matrix_vec);

        const block_a_x = if (blocks_per_macroblock == 2)
            (slice_pos.x >> 1) + ((j >> 1) << 3)
        else
            slice_pos.x + ((j >> 2) << 4);
        const block_a_y = if (blocks_per_macroblock == 2)
            slice_pos.y
        else
            slice_pos.y + ((j & 2) << 2);

        const block_b_x = if (blocks_per_macroblock == 2)
            block_a_x
        else
            block_a_x + 8;
        const block_b_y = if (blocks_per_macroblock == 2)
            block_a_y + 8
        else
            block_a_y;

        // Copy into frame data
        inline for (0..8) |row| {
            @memcpy(
                frame_data[coded_width * (block_a_y + row) + block_a_x ..][0..8],
                result_a[8 * row ..][0..8],
            );
            @memcpy(
                frame_data[coded_width * (block_b_y + row) + block_b_x ..][0..8],
                result_b[8 * row ..][0..8],
            );
        }
    }
}

const SlicePos = struct { x: u32, y: u32 };

inline fn getSlicePos(index: usize, slices_per_row: usize, slice_width: u32, slice_height: u32) SlicePos {
    const index_in_row = index % slices_per_row;
    const row_index = index / slices_per_row;

    return .{
        .x = @intCast(index_in_row * (slice_width << 4)),
        .y = @intCast(row_index * (slice_height << 4)),
    };
}

fn decodePacketInternal(decoder: *Decoder) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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

    // Fold the dequantization and AAN scaling factors into a single matrix
    var luma_scaling_matrix: [64]f32 = undefined;
    inline for (0..8) |x| {
        inline for (0..8) |y| {
            const i = 8 * y + x;
            luma_scaling_matrix[i] = @floatFromInt(q_mat_luma[8 * x + y]); // Read the matrix transposed-ly
            luma_scaling_matrix[i] *= 0.25; // >> 2
            luma_scaling_matrix[i] *= comptime 1 / (S[x] * S[y]);
        }
    }

    const q_mat_chroma: [64]u8 = if (q_mat_flags & 0b01 != 0)
        reader.takeArray(64).*
    else
        @splat(4);

    var chroma_scaling_matrix: [64]f32 = undefined;
    inline for (0..8) |x| {
        inline for (0..8) |y| {
            const i = 8 * y + x;
            chroma_scaling_matrix[i] = @floatFromInt(q_mat_chroma[8 * x + y]); // Read the matrix transposed-ly
            chroma_scaling_matrix[i] *= 0.25; // >> 2
            chroma_scaling_matrix[i] *= comptime 1 / (S[x] * S[y]);
        }
    }

    std.debug.assert(chrominance_factor == 2); // 422

    printValues(.{ frame_size, frame_type_outer, hdr_size, version, creator_id, frame_width, frame_height, frame_flags, chrominance_factor, frame_type, primaries, transfer_function, color_matrix, src_pix_format, alpha_info, q_mat_flags, q_mat_luma, q_mat_chroma });

    decoder.display_width = frame_width;
    decoder.display_height = frame_height;
    decoder.coded_width = (frame_width + 15) & ~@as(u32, 15);
    decoder.coded_height = (frame_height + 15) & ~@as(u32, 15);

    const frame_data_size = decoder.coded_width * decoder.coded_height * 2;
    decoder.frame_data = try gpa.realloc(decoder.frame_data, frame_data_size);

    const pic_hdr_size = reader.takeInt(u8);
    const pic_data_size = reader.takeInt(u32);
    const total_slices = reader.takeInt(u16);
    const slice_dimensions = reader.takeInt(u8);
    const slice_width = @as(u32, 1) << @as(u5, @intCast(slice_dimensions >> 4));
    const slice_height = @as(u32, 1) << @as(u5, @intCast(slice_dimensions & 0b1111));

    const slice_sizes = try arena.alloc(u16, total_slices);
    for (0..total_slices) |i| {
        slice_sizes[i] = reader.takeInt(u16);
    }

    const slice_offsets = try arena.alloc(usize, total_slices);

    var current_offset: usize = reader.pos;
    for (0..total_slices) |i| {
        slice_offsets[i] = current_offset;
        current_offset += slice_sizes[i];
    }

    const num_luma_blocks = 4 * slice_width * slice_height;
    const num_chroma_blocks = 2 * slice_width * slice_height;

    const luma_slice_len = 64 * num_luma_blocks;
    const chroma_slice_len = 64 * num_chroma_blocks;

    const slice_data = try arena.alloc(f32, 2 * luma_slice_len + 4 * chroma_slice_len);

    printValues(.{ pic_hdr_size, pic_data_size, total_slices, slice_dimensions, slice_width, slice_height, slice_sizes });

    const luma_slices_per_row = (decoder.coded_width + (slice_width << 4) - 1) / ((slice_width << 4));

    const slice_indices = try arena.alloc(usize, total_slices);

    for (0..total_slices) |i| {
        slice_indices[i] = i;
    }

    if (true) {
        const Context = struct {
            items: []u16,

            fn sort(self: @This(), a: usize, b: usize) bool {
                return self.items[a] < self.items[b];
            }
        };
        const ctx = Context{
            .items = slice_sizes,
        };

        std.mem.sortUnstable(usize, slice_indices, ctx, Context.sort);
    }

    const chroma_entries = (decoder.coded_width * decoder.coded_height) / 2;
    const luma_frame_data = decoder.frame_data[0 .. decoder.coded_width * decoder.coded_height];
    const u_frame_data = decoder.frame_data[decoder.coded_width * decoder.coded_height ..][0..chroma_entries];
    const v_frame_data = decoder.frame_data[decoder.coded_width * decoder.coded_height + chroma_entries ..][0..chroma_entries];

    const slice_1_luma_data = slice_data[0..luma_slice_len];
    const slice_2_luma_data = slice_data[luma_slice_len..][0..luma_slice_len];
    const slice_1_u_data = slice_data[2 * luma_slice_len ..][0..chroma_slice_len];
    const slice_2_u_data = slice_data[2 * luma_slice_len + chroma_slice_len ..][0..chroma_slice_len];
    const slice_1_v_data = slice_data[2 * luma_slice_len + 2 * chroma_slice_len ..][0..chroma_slice_len];
    const slice_2_v_data = slice_data[2 * luma_slice_len + 3 * chroma_slice_len ..][0..chroma_slice_len];

    var i: usize = 0;
    while (i + 1 < total_slices) : (i += 2) {
        const index_1 = slice_indices[i];
        const index_2 = slice_indices[i + 1];
        reader.pos = slice_offsets[index_1];
        var header_1 = parseSliceHeader(slice_sizes, &reader, index_1);
        reader.pos = slice_offsets[index_2];
        var header_2 = parseSliceHeader(slice_sizes, &reader, index_2);

        // AC parameters are sparse, so we must memset them all to zero
        @memset(slice_data, 0);

        const pos_1 = getSlicePos(index_1, luma_slices_per_row, slice_width, slice_height);
        const pos_2 = getSlicePos(index_2, luma_slices_per_row, slice_width, slice_height);

        // Fold each slice's quantization scale into its matrices up front. The U and V planes of a slice
        // share the same chroma matrix, so this also avoids redoing that multiply for both.
        const scale_1: @Vector(64, f32) = @splat(@floatFromInt(header_1.scale_factor));
        const scale_2: @Vector(64, f32) = @splat(@floatFromInt(header_2.scale_factor));
        const luma_vec_1 = @as(@Vector(64, f32), luma_scaling_matrix) * scale_1;
        const luma_vec_2 = @as(@Vector(64, f32), luma_scaling_matrix) * scale_2;
        const chroma_vec_1 = @as(@Vector(64, f32), chroma_scaling_matrix) * scale_1;
        const chroma_vec_2 = @as(@Vector(64, f32), chroma_scaling_matrix) * scale_2;

        // Luma for slice 1 and 2
        parseDcPair(
            &header_1.luma_bit_reader,
            &header_2.luma_bit_reader,
            slice_1_luma_data,
            slice_2_luma_data,
            num_luma_blocks,
        );
        parseAcPair(
            &header_1.luma_bit_reader,
            &header_2.luma_bit_reader,
            slice_1_luma_data,
            slice_2_luma_data,
            num_luma_blocks,
        );
        transformAndStoreSliceData(
            decoder,
            slice_1_luma_data,
            luma_frame_data,
            luma_vec_1,
            pos_1,
            num_luma_blocks,
            4,
        );
        transformAndStoreSliceData(
            decoder,
            slice_2_luma_data,
            luma_frame_data,
            luma_vec_2,
            pos_2,
            num_luma_blocks,
            4,
        );

        // U for slice 1 and 2
        parseDcPair(
            &header_1.u_bit_reader,
            &header_2.u_bit_reader,
            slice_1_u_data,
            slice_2_u_data,
            num_chroma_blocks,
        );
        parseAcPair(
            &header_1.u_bit_reader,
            &header_2.u_bit_reader,
            slice_1_u_data,
            slice_2_u_data,
            num_chroma_blocks,
        );
        transformAndStoreSliceData(
            decoder,
            slice_1_u_data,
            u_frame_data,
            chroma_vec_1,
            pos_1,
            num_chroma_blocks,
            2,
        );
        transformAndStoreSliceData(
            decoder,
            slice_2_u_data,
            u_frame_data,
            chroma_vec_2,
            pos_2,
            num_chroma_blocks,
            2,
        );

        // V for slice 1 and 2
        parseDcPair(
            &header_1.v_bit_reader,
            &header_2.v_bit_reader,
            slice_1_v_data,
            slice_2_v_data,
            num_chroma_blocks,
        );
        parseAcPair(
            &header_1.v_bit_reader,
            &header_2.v_bit_reader,
            slice_1_v_data,
            slice_2_v_data,
            num_chroma_blocks,
        );
        transformAndStoreSliceData(
            decoder,
            slice_1_v_data,
            v_frame_data,
            chroma_vec_1,
            pos_1,
            num_chroma_blocks,
            2,
        );
        transformAndStoreSliceData(
            decoder,
            slice_2_v_data,
            v_frame_data,
            chroma_vec_2,
            pos_2,
            num_chroma_blocks,
            2,
        );
    }

    // Odd slice count leaves one slice over; decode it on its own
    if (i < total_slices) {
        const index = slice_indices[i];
        reader.pos = slice_offsets[index];
        var header = parseSliceHeader(slice_sizes, &reader, index);

        @memset(slice_data[0 .. luma_slice_len + 2 * chroma_slice_len], 0);

        const luma_data = slice_data[0..luma_slice_len];
        const u_data = slice_data[luma_slice_len..][0..chroma_slice_len];
        const v_data = slice_data[luma_slice_len + chroma_slice_len ..][0..chroma_slice_len];

        const pos = getSlicePos(index, luma_slices_per_row, slice_width, slice_height);

        const scale: @Vector(64, f32) = @splat(@floatFromInt(header.scale_factor));
        const luma_vec = @as(@Vector(64, f32), luma_scaling_matrix) * scale;
        const chroma_vec = @as(@Vector(64, f32), chroma_scaling_matrix) * scale;

        // Luma
        parseDcSingle(&header.luma_bit_reader, luma_data, num_luma_blocks);
        parseAcSingle(&header.luma_bit_reader, luma_data, num_luma_blocks);
        transformAndStoreSliceData(decoder, luma_data, luma_frame_data, luma_vec, pos, num_luma_blocks, 4);

        // U
        parseDcSingle(&header.u_bit_reader, u_data, num_chroma_blocks);
        parseAcSingle(&header.u_bit_reader, u_data, num_chroma_blocks);
        transformAndStoreSliceData(decoder, u_data, u_frame_data, chroma_vec, pos, num_chroma_blocks, 2);

        // V
        parseDcSingle(&header.v_bit_reader, v_data, num_chroma_blocks);
        parseAcSingle(&header.v_bit_reader, v_data, num_chroma_blocks);
        transformAndStoreSliceData(decoder, v_data, v_frame_data, chroma_vec, pos, num_chroma_blocks, 2);
    }
}

const S = [_]f32{
    8 * 0.353553390593273762200422,
    8 * 0.254897789552079584470970,
    8 * 0.270598050073098492199862,
    8 * 0.300672443467522640271861,
    8 * 0.353553390593273762200422,
    8 * 0.449988111568207852319255,
    8 * 0.653281482438188263928322,
    8 * 1.281457723870753089398043,
};

const A = [_]f32{
    std.math.nan(f32),
    0.707106781186547524400844,
    0.541196100146196984399723,
    0.707106781186547524400844,
    1.306562964876376527856643,
    0.382683432365089771728460,
};

pub inline fn fastMin(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    const c = a - b;
    return a - (c + @abs(c)) * @as(@TypeOf(a), @splat(0.5)); // splat(@TypeOf(a), 0.5);
}

inline fn idct_8x8(block: [64]f32, scaling_matrix: @Vector(64, f32)) [64]u16 {
    var float_block: [64]f32 = block;

    const Vec = @Vector(64, f32);
    var float_vec: Vec = float_block;
    float_vec *= scaling_matrix;
    float_vec[0] += comptime 4096 / (S[0] * S[0]); // Add the DC dequant offset but pre-scaled

    float_block = float_vec;

    idct_columns(&float_block);
    float_block = transpose_8x8(f32, float_block);
    idct_columns(&float_block);

    float_vec = float_block;

    // WASM doesn't have a neat f32->u16 instruction, so we first do f32->u32, followed by u32->u16!
    var as_u32: @Vector(64, u32) = @intFromFloat(float_vec);

    // Already clamped at 0 due to the f32->u32 conversion, now let's clamp the upper end (it's faster for int than
    // for float).
    as_u32 = @min(as_u32, @as(@Vector(64, u32), @splat(1023)));

    return @as(@Vector(64, u16), @intCast(as_u32));
}

// Based on https://www.nayuki.io/res/fast-discrete-cosine-transform-algorithms/fast-dct-8.c
inline fn idct_columns(block: *[64]f32) void {
    const V = @Vector(8, f32);

    const v15: V = block[0..8].*;
    const v26: V = block[8..16].*;
    const v21: V = block[16..24].*;
    const v28: V = block[24..32].*;
    const v16: V = block[32..40].*;
    const v25: V = block[40..48].*;
    const v22: V = block[48..56].*;
    const v27: V = block[56..64].*;

    const v19 = v25 - v28;
    const v20 = v26 - v27;
    const v23 = v26 + v27;
    const v24 = v25 + v28;

    const v7 = v23 + v24;
    const v11 = v21 + v22;
    const v13 = v23 - v24;
    const v17 = v21 - v22;

    const v8 = v15 + v16;
    const v9 = v15 - v16;

    const denom = comptime 2.0 / (A[2] * A[5] - A[2] * A[4] - A[4] * A[5]);
    const a5 = comptime A[5] * denom;
    const a4 = comptime A[4] * denom;
    const a2 = comptime A[2] * denom;

    const v18 = (v19 - v20) * @as(V, @splat(a5));
    const v12 = v19 * @as(V, @splat(a4)) - v18;
    const v14 = v18 - v20 * @as(V, @splat(a2));

    const v6 = v14 - v7;
    const v5 = v13 * @as(V, @splat(comptime 1.0 / A[3])) - v6;
    const v4 = v5 + v12;
    const v10 = v17 * @as(V, @splat(comptime 1.0 / A[1])) - v11;

    const v0 = v8 + v11;
    const v1 = v9 + v10;
    const v2 = v9 - v10;
    const v3 = v8 - v11;

    block[0..8].* = v0 + v7;
    block[8..16].* = v1 + v6;
    block[16..24].* = v2 + v5;
    block[24..32].* = v3 - v4;
    block[32..40].* = v3 + v4;
    block[40..48].* = v2 - v5;
    block[48..56].* = v1 - v6;
    block[56..64].* = v0 - v7;
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
