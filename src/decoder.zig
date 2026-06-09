const std = @import("std");
const misc = @import("./misc.zig");
const gpa = misc.gpa;
const io = misc.io;
const worker = @import("./worker.zig");

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

pub const Decoder = struct {
    packet: []u8,
    frame_data: []align(16) u16,
    coded_width: u32,
    coded_height: u32,
    display_width: u32,
    display_height: u32,
    slice_width: u32,
    slice_info_in_row: std.MultiArrayList(SliceInfo),
    max_slice_width: u32,
    slice_indices: []usize,
    slice_sizes: []usize,
    slice_offsets: []usize,
    luma_scaling_matrix: [64]f32,
    chroma_scaling_matrix: [64]f32,
    log2_chroma_blocks_per_mb: u5,
    alpha_bit_depth: u32,
    bit_depth: u32,
    tasks: []worker.WorkerDecodeTask,
    running_task_count: std.atomic.Value(u32),
    wait_word: u32,
};

const SliceInfo = struct {
    pos: u16,
    size: u8,
};

const SlicePos = struct {
    x: u32,
    y: u32,
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
        .slice_width = undefined,
        .slice_info_in_row = .empty,
        .max_slice_width = undefined,
        .slice_indices = &.{},
        .slice_sizes = &.{},
        .slice_offsets = &.{},
        .luma_scaling_matrix = undefined,
        .chroma_scaling_matrix = undefined,
        .log2_chroma_blocks_per_mb = undefined,
        .alpha_bit_depth = undefined,
        .bit_depth = 10, // Hardcoded for now, must be passed in from the outside
        .tasks = &.{},
        .running_task_count = .init(0),
        .wait_word = 0,
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

export fn getFrameDataSize(decoder: *Decoder) usize {
    return decoder.frame_data.len;
}

export fn getChromaSubsampling(decoder: *Decoder) u32 {
    return if (decoder.log2_chroma_blocks_per_mb == 2) 444 else 422;
}

export fn getBitDepth(decoder: *Decoder) u32 {
    return decoder.bit_depth;
}

export fn getAlphaBitDepth(decoder: *Decoder) u32 {
    return decoder.alpha_bit_depth;
}

export fn closeDecoder(decoder: *Decoder) void {
    gpa.free(decoder.packet);
    gpa.free(decoder.frame_data);
    decoder.slice_info_in_row.deinit(gpa);
    gpa.free(decoder.slice_indices);
    gpa.free(decoder.slice_sizes);
    gpa.free(decoder.slice_offsets);
    gpa.free(decoder.tasks);
    gpa.destroy(decoder);
}

export fn allocatePacket(decoder: *Decoder, size: usize) [*]u8 {
    decoder.packet = gpa.realloc(decoder.packet, size) catch unreachable;
    return decoder.packet.ptr;
}

export fn getWaitWordAddress(decoder: *Decoder) *u32 {
    return &decoder.wait_word;
}

export fn decodePacket(decoder: *Decoder) i32 {
    decodePacketInternal(decoder) catch return -1;

    return 0;
}

fn decodePacketInternal(decoder: *Decoder) !void {
    var reader = misc.ByteReader.init(decoder.packet);

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

    _ = .{ frame_size, frame_type_outer, hdr_size, version, creator_id, frame_width, frame_height, frame_flags, chrominance_factor, frame_type, primaries, transfer_function, color_matrix, next_byte, src_pix_format, alpha_info, q_mat_flags };

    const q_mat_luma: [64]u8 = if (q_mat_flags & 0b10 != 0)
        reader.takeArray(64).*
    else
        @splat(4);

    // Fold the dequantization and AAN scaling factors into a single matrix
    inline for (0..8) |x| {
        inline for (0..8) |y| {
            const i = 8 * y + x;
            decoder.luma_scaling_matrix[i] = @floatFromInt(q_mat_luma[8 * x + y]); // Read the matrix transposed-ly
            decoder.luma_scaling_matrix[i] *= 0.25; // >> 2
            decoder.luma_scaling_matrix[i] *= comptime 1 / (S[x] * S[y]);
        }
    }

    const q_mat_chroma: [64]u8 = if (q_mat_flags & 0b01 != 0)
        reader.takeArray(64).*
    else
        @splat(4);

    inline for (0..8) |x| {
        inline for (0..8) |y| {
            const i = 8 * y + x;
            decoder.chroma_scaling_matrix[i] = @floatFromInt(q_mat_chroma[8 * x + y]); // Read the matrix transposed-ly
            decoder.chroma_scaling_matrix[i] *= 0.25; // >> 2
            decoder.chroma_scaling_matrix[i] *= comptime 1 / (S[x] * S[y]);
        }
    }

    std.debug.assert(chrominance_factor == 2 or chrominance_factor == 3);
    decoder.log2_chroma_blocks_per_mb = if (chrominance_factor == 2) 1 else 2;

    decoder.alpha_bit_depth = alpha_info << 3;

    decoder.display_width = frame_width;
    decoder.display_height = frame_height;
    decoder.coded_width = (frame_width + 15) & ~@as(u32, 15);
    decoder.coded_height = (frame_height + 15) & ~@as(u32, 15);

    var multiplier = decoder.log2_chroma_blocks_per_mb + 1;
    if (alpha_info != 0) {
        multiplier += 1;
    }

    const frame_data_size = multiplier * (decoder.coded_width * decoder.coded_height);
    decoder.frame_data = try gpa.realloc(decoder.frame_data, frame_data_size);

    const pic_hdr_size = reader.takeInt(u8);
    const pic_data_size = reader.takeInt(u32);
    const total_slices = reader.takeInt(u16);
    const slice_dimensions = reader.takeInt(u8);

    _ = pic_hdr_size;
    _ = pic_data_size;

    decoder.slice_width = @as(u32, 1) << @as(u5, @intCast(slice_dimensions >> 4));
    // Apparently all other decoders only support this value, and therefore no encoder emits anything but this value, so
    // we can hardcode it to simplify the code.
    //decoder.slice_height = @as(u32, 1) << @as(u5, @intCast(slice_dimensions & 0b1111));

    decoder.slice_info_in_row.clearRetainingCapacity();
    decoder.max_slice_width = 0;

    var current_x: u16 = 0;
    const coded_width_in_macroblocks = decoder.coded_width >> 4;
    while (current_x < coded_width_in_macroblocks) {
        var width: u8 = @intCast(decoder.slice_width);
        while (current_x + width > coded_width_in_macroblocks) {
            width >>= 1;
        }

        try decoder.slice_info_in_row.append(gpa, .{
            .pos = current_x,
            .size = width,
        });
        current_x += width;

        if (decoder.max_slice_width == 0) {
            // The first slice has the maximum width (no other slice has a longer width)
            decoder.max_slice_width = width;
        }
    }

    const fixed_per_slice = 100;

    var total_slice_size: usize = 0;
    decoder.slice_sizes = try gpa.realloc(decoder.slice_sizes, total_slices);
    for (0..total_slices) |i| {
        const size: usize = reader.takeInt(u16);

        decoder.slice_sizes[i] = size;
        total_slice_size += size + fixed_per_slice;
    }

    decoder.slice_offsets = try gpa.realloc(decoder.slice_offsets, total_slices);

    var current_offset: usize = reader.pos;
    for (0..total_slices) |i| {
        decoder.slice_offsets[i] = current_offset;
        current_offset += decoder.slice_sizes[i];
    }

    decoder.slice_indices = try gpa.realloc(decoder.slice_indices, total_slices);

    for (0..total_slices) |i| {
        decoder.slice_indices[i] = i;
    }

    if (false) {
        const Context = struct {
            items: []usize,

            fn sort(self: @This(), a: usize, b: usize) bool {
                return self.items[a] < self.items[b];
            }
        };
        const ctx = Context{
            .items = decoder.slice_sizes,
        };

        std.mem.sortUnstable(usize, decoder.slice_indices, ctx, Context.sort);
    }

    misc.lockMutex(&worker.worker_task_queue_mutex);
    defer worker.worker_task_queue_mutex.unlock(io);

    const num_workers_val = worker.num_workers.load(.monotonic);

    const size_per_worker = total_slice_size / num_workers_val;

    decoder.tasks = try gpa.realloc(decoder.tasks, num_workers_val);

    var slice_start_index: usize = 0;

    for (0..num_workers_val) |i| {
        const start_index = slice_start_index;

        var current_size: usize = 0;
        while (slice_start_index < total_slices) : (slice_start_index += 1) {
            if (current_size >= size_per_worker) {
                break;
            }

            current_size += decoder.slice_sizes[decoder.slice_indices[slice_start_index]] + fixed_per_slice;
        }

        decoder.tasks[i] = .{
            .decoder = decoder,
            .slice_start = start_index,
            .slice_count = slice_start_index - start_index,
        };

        try worker.worker_task_queue.pushBack(gpa, .{
            .decode = &decoder.tasks[i],
        });
    }

    io.futexWake(u32, &worker.worker_task_queue.len, num_workers_val);

    decoder.running_task_count.store(num_workers_val, .monotonic);
}

pub fn executeDecodeTask(task: *worker.WorkerDecodeTask) !void {
    const decoder = task.decoder;
    const slice_count = task.slice_count;
    const slice_start = task.slice_start;

    var reader = misc.ByteReader.init(decoder.packet);

    const max_num_luma_blocks = decoder.max_slice_width << 2;
    const max_num_chroma_blocks = decoder.max_slice_width << decoder.log2_chroma_blocks_per_mb;

    const max_luma_slice_len = max_num_luma_blocks << 6;
    const max_chroma_slice_len = max_num_chroma_blocks << 6;

    const luma_scaling_matrix = decoder.luma_scaling_matrix;
    const chroma_scaling_matrix = decoder.chroma_scaling_matrix;

    const chroma_entries = (decoder.coded_width * decoder.coded_height) >> @as(u5, @intCast(2 - decoder.log2_chroma_blocks_per_mb));
    const luma_frame_data = decoder.frame_data[0 .. decoder.coded_width * decoder.coded_height];
    const u_frame_data = decoder.frame_data[decoder.coded_width * decoder.coded_height ..][0..chroma_entries];
    const v_frame_data = decoder.frame_data[decoder.coded_width * decoder.coded_height + chroma_entries ..][0..chroma_entries];
    const alpha_frame_data = decoder.frame_data[decoder.coded_width * decoder.coded_height + (chroma_entries << 1) ..];

    // Aligned for SIMD access
    const slice_data = try gpa.alignedAlloc(f32, .@"16", (max_luma_slice_len + (max_chroma_slice_len << 1)) << 1);
    defer gpa.free(slice_data);

    const slice_1_luma_data = slice_data[0..max_luma_slice_len];
    const slice_2_luma_data = slice_data[max_luma_slice_len..][0..max_luma_slice_len];
    const slice_1_u_data = slice_data[(max_luma_slice_len << 1)..][0..max_chroma_slice_len];
    const slice_2_u_data = slice_data[(max_luma_slice_len << 1) + 1 * max_chroma_slice_len ..][0..max_chroma_slice_len];
    const slice_1_v_data = slice_data[(max_luma_slice_len << 1) + 2 * max_chroma_slice_len ..][0..max_chroma_slice_len];
    const slice_2_v_data = slice_data[(max_luma_slice_len << 1) + 3 * max_chroma_slice_len ..][0..max_chroma_slice_len];

    const has_alpha = decoder.alpha_bit_depth != 0;

    var i: usize = 0;
    while (i + 1 < slice_count) : (i += 2) {
        const index_1 = decoder.slice_indices[slice_start + i];
        const index_2 = decoder.slice_indices[slice_start + i + 1];
        reader.pos = decoder.slice_offsets[index_1];
        const header_1 = parseSliceHeader(decoder, &reader, index_1);
        reader.pos = decoder.slice_offsets[index_2];
        const header_2 = parseSliceHeader(decoder, &reader, index_2);

        // AC parameters are sparse, so we must memset them all to zero
        @memset(slice_data, 0);

        const pos_1 = SlicePos{
            .x = header_1.pos_x_mb << 4,
            .y = header_1.pos_y_mb << 4,
        };
        const pos_2 = SlicePos{
            .x = header_2.pos_x_mb << 4,
            .y = header_2.pos_y_mb << 4,
        };

        // Fold each slice's quantization scale into its matrices up front. The U and V planes of a slice
        // share the same chroma matrix, so this also avoids redoing that multiply for both.
        const scale_1: @Vector(64, f32) = @splat(@floatFromInt(header_1.scale_factor));
        const scale_2: @Vector(64, f32) = @splat(@floatFromInt(header_2.scale_factor));
        const luma_vec_1 = @as(@Vector(64, f32), luma_scaling_matrix) * scale_1;
        const luma_vec_2 = @as(@Vector(64, f32), luma_scaling_matrix) * scale_2;
        const chroma_vec_1 = @as(@Vector(64, f32), chroma_scaling_matrix) * scale_1;
        const chroma_vec_2 = @as(@Vector(64, f32), chroma_scaling_matrix) * scale_2;

        const num_luma_blocks_1 = header_1.width_mb << 2;
        const num_luma_blocks_2 = header_2.width_mb << 2;
        const num_chroma_blocks_1 = header_1.width_mb << decoder.log2_chroma_blocks_per_mb;
        const num_chroma_blocks_2 = header_2.width_mb << decoder.log2_chroma_blocks_per_mb;

        // Luma for slice 1 and 2
        parseDcAndAcPair(
            header_1.luma_data,
            header_2.luma_data,
            slice_1_luma_data,
            slice_2_luma_data,
            num_luma_blocks_1,
            num_luma_blocks_2,
        );
        transformAndStoreSliceData(
            decoder,
            slice_1_luma_data,
            luma_frame_data,
            luma_vec_1,
            pos_1,
            num_luma_blocks_1,
            2,
            false,
        );
        transformAndStoreSliceData(
            decoder,
            slice_2_luma_data,
            luma_frame_data,
            luma_vec_2,
            pos_2,
            num_luma_blocks_2,
            2,
            false,
        );

        // U for slice 1 and 2
        parseDcAndAcPair(
            header_1.u_data,
            header_2.u_data,
            slice_1_u_data,
            slice_2_u_data,
            num_chroma_blocks_1,
            num_chroma_blocks_2,
        );
        transformAndStoreSliceData(
            decoder,
            slice_1_u_data,
            u_frame_data,
            chroma_vec_1,
            pos_1,
            num_chroma_blocks_1,
            decoder.log2_chroma_blocks_per_mb,
            true,
        );
        transformAndStoreSliceData(
            decoder,
            slice_2_u_data,
            u_frame_data,
            chroma_vec_2,
            pos_2,
            num_chroma_blocks_2,
            decoder.log2_chroma_blocks_per_mb,
            true,
        );

        // V for slice 1 and 2
        parseDcAndAcPair(
            header_1.v_data,
            header_2.v_data,
            slice_1_v_data,
            slice_2_v_data,
            num_chroma_blocks_1,
            num_chroma_blocks_2,
        );
        transformAndStoreSliceData(
            decoder,
            slice_1_v_data,
            v_frame_data,
            chroma_vec_1,
            pos_1,
            num_chroma_blocks_1,
            decoder.log2_chroma_blocks_per_mb,
            true,
        );
        transformAndStoreSliceData(
            decoder,
            slice_2_v_data,
            v_frame_data,
            chroma_vec_2,
            pos_2,
            num_chroma_blocks_2,
            decoder.log2_chroma_blocks_per_mb,
            true,
        );

        if (has_alpha) {
            switch (decoder.alpha_bit_depth) {
                inline 8, 16 => |source_bit_depth| {
                    switch (decoder.bit_depth) {
                        inline 10, 12 => |target_bit_depth| {
                            // Alpha is not decoded in an interleaved fashion, because it was slower than the
                            // naive approach

                            // Alpha for slice 1
                            parseAndStoreAlpha(
                                header_1.alpha_data,
                                alpha_frame_data,
                                pos_1.x,
                                pos_1.y,
                                header_1.width_mb << 4,
                                num_luma_blocks_1 << 6,
                                decoder.coded_width,
                                source_bit_depth,
                                target_bit_depth,
                            );
                            // Alpha for slice 2
                            parseAndStoreAlpha(
                                header_2.alpha_data,
                                alpha_frame_data,
                                pos_2.x,
                                pos_2.y,
                                header_2.width_mb << 4,
                                num_luma_blocks_2 << 6,
                                decoder.coded_width,
                                source_bit_depth,
                                target_bit_depth,
                            );
                        },
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
        }
    }

    // Odd slice count leaves one slice over; decode it on its own
    if (i < slice_count) {
        const index = decoder.slice_indices[slice_start + i];
        reader.pos = decoder.slice_offsets[index];
        const header = parseSliceHeader(decoder, &reader, index);

        const num_luma_blocks = header.width_mb << 2;
        const num_chroma_blocks = header.width_mb << decoder.log2_chroma_blocks_per_mb;
        const luma_slice_len = num_luma_blocks << 6;
        const chroma_slice_len = num_chroma_blocks << 6;

        @memset(slice_data[0 .. luma_slice_len + (chroma_slice_len << 1)], 0);

        const luma_data = slice_data[0..luma_slice_len];
        const u_data = slice_data[luma_slice_len..][0..chroma_slice_len];
        const v_data = slice_data[luma_slice_len + chroma_slice_len ..][0..chroma_slice_len];

        const pos = SlicePos{
            .x = header.pos_x_mb << 4,
            .y = header.pos_y_mb << 4,
        };

        const scale: @Vector(64, f32) = @splat(@floatFromInt(header.scale_factor));
        const luma_vec = @as(@Vector(64, f32), luma_scaling_matrix) * scale;
        const chroma_vec = @as(@Vector(64, f32), chroma_scaling_matrix) * scale;

        // Luma
        parseDcAndAcSingle(header.luma_data, luma_data, num_luma_blocks);
        transformAndStoreSliceData(
            decoder,
            luma_data,
            luma_frame_data,
            luma_vec,
            pos,
            num_luma_blocks,
            2,
            false,
        );

        // U
        parseDcAndAcSingle(header.u_data, u_data, num_chroma_blocks);
        transformAndStoreSliceData(
            decoder,
            u_data,
            u_frame_data,
            chroma_vec,
            pos,
            num_chroma_blocks,
            decoder.log2_chroma_blocks_per_mb,
            true,
        );

        // V
        parseDcAndAcSingle(header.v_data, v_data, num_chroma_blocks);
        transformAndStoreSliceData(
            decoder,
            v_data,
            v_frame_data,
            chroma_vec,
            pos,
            num_chroma_blocks,
            decoder.log2_chroma_blocks_per_mb,
            true,
        );

        if (has_alpha) {
            switch (decoder.alpha_bit_depth) {
                inline 8, 16 => |source_bit_depth| {
                    switch (decoder.bit_depth) {
                        inline 10, 12 => |target_bit_depth| {
                            parseAndStoreAlpha(
                                header.alpha_data,
                                alpha_frame_data,
                                pos.x,
                                pos.y,
                                header.width_mb << 4,
                                num_luma_blocks << 6,
                                decoder.coded_width,
                                source_bit_depth,
                                target_bit_depth,
                            );
                        },
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
        }
    }

    if (decoder.running_task_count.fetchSub(1, .monotonic) == 1) {
        io.futexWake(u32, &decoder.wait_word, 4);
    }
}

const SliceHeader = struct {
    scale_factor: u32,
    luma_data: []u8,
    u_data: []u8,
    v_data: []u8,
    alpha_data: []u8,
    width_mb: u32,
    pos_x_mb: u32,
    pos_y_mb: u32,
};

inline fn parseSliceHeader(decoder: *Decoder, reader: *misc.ByteReader, i: usize) SliceHeader {
    const slice_size = decoder.slice_sizes[i];
    const slice_hdr_size = reader.takeInt(u8) >> 3;

    var scale_factor: u32 = reader.takeInt(u8);
    if (scale_factor > 128) {
        scale_factor = (scale_factor - 96) << 2;
    }

    const luma_data_size = reader.takeInt(u16);
    const u_data_size = reader.takeInt(u16);
    const v_data_size = if (slice_hdr_size >= 8)
        reader.takeInt(u16) // There's a special field for V data size
    else
        slice_size - luma_data_size - u_data_size - slice_hdr_size;
    const alpha_data_size = slice_size - luma_data_size - u_data_size - v_data_size - slice_hdr_size;

    const luma_data = reader.take(luma_data_size);
    const u_data = reader.take(u_data_size);
    const v_data = reader.take(v_data_size);
    const alpha_data = reader.take(alpha_data_size);

    const y_index = i / decoder.slice_info_in_row.len;
    const x_index = i - y_index * decoder.slice_info_in_row.len; // No % so we don't need two int divisions

    return .{
        .scale_factor = scale_factor,
        .luma_data = luma_data,
        .u_data = u_data,
        .v_data = v_data,
        .alpha_data = alpha_data,
        .width_mb = decoder.slice_info_in_row.items(.size)[x_index],
        .pos_x_mb = decoder.slice_info_in_row.items(.pos)[x_index],
        .pos_y_mb = y_index,
    };
}

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

fn transpose_scan_values(s: [64]u8) [64]u8 {
    var result: [64]u8 = undefined;

    for (s, 0..) |pos, i| {
        result[i] = 8 * (pos % 8) + (pos / 8);
    }

    return result;
}

const run_params = [_]u8{ 0x06, 0x06, 0x05, 0x05, 0x04, 0x29, 0x29, 0x29, 0x29, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x4C };
const level_params = [_]u8{ 0x04, 0x0A, 0x05, 0x06, 0x04, 0x28, 0x28, 0x28, 0x28, 0x4C };
const dc_params = [_]u8{ 0x04, 0x28, 0x28, 0x4D, 0x4D, 0x70, 0x70 };

fn parseDcAndAcPair(
    data_1: []u8,
    data_2: []u8,
    slice_1_data: []f32,
    slice_2_data: []f32,
    num_blocks_1: u32,
    num_blocks_2: u32,
) void {
    var dc_state_1 = DcState.init(data_1, slice_1_data);
    var dc_state_2 = DcState.init(data_2, slice_2_data);

    var j: u32 = 2;
    const min_num_blocks = @min(num_blocks_1, num_blocks_2);
    while (j < min_num_blocks) : (j += 2) {
        dc_state_1.step(j);
        dc_state_2.step(j);
    }
    while (j < num_blocks_1) : (j += 2) dc_state_1.step(j);
    while (j < num_blocks_2) : (j += 2) dc_state_2.step(j);

    const log2_block_count_1: u5 = @intCast(std.math.log2_int(u32, num_blocks_1));
    const log2_block_count_2: u5 = @intCast(std.math.log2_int(u32, num_blocks_2));
    const block_mask_1 = num_blocks_1 - 1;
    const block_mask_2 = num_blocks_2 - 1;

    var ac_state_1 = AcState{
        .bit_reader = dc_state_1.bit_reader,
        .slice_data = slice_1_data,
        .pos = block_mask_1,
        .log2_block_count = log2_block_count_1,
        .block_mask = block_mask_1,
    };
    var ac_state_2 = AcState{
        .bit_reader = dc_state_2.bit_reader,
        .slice_data = slice_2_data,
        .pos = block_mask_2,
        .log2_block_count = log2_block_count_2,
        .block_mask = block_mask_2,
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

fn parseDcAndAcSingle(data: []u8, slice_data: []f32, num_blocks: u32) void {
    var dc_state = DcState.init(data, slice_data);

    var j: u32 = 2;
    while (j < num_blocks) : (j += 2) {
        dc_state.step(j);
    }

    const log2_block_count: u5 = @intCast(std.math.log2_int(u32, num_blocks));
    const block_mask = num_blocks - 1;

    var ac_state = AcState{
        .bit_reader = dc_state.bit_reader,
        .slice_data = slice_data,
        .pos = block_mask,
        .log2_block_count = log2_block_count,
        .block_mask = block_mask,
    };

    while (ac_state.step()) {}
}

const DcState = struct {
    bit_reader: misc.BitReader,
    slice_data: []f32,
    code: i32,
    sign: i32,
    prev_dc: i32,

    inline fn init(data: []u8, slice_data: []f32) DcState {
        var s = DcState{
            .bit_reader = misc.BitReader.fromData(data),
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

        const code_result_1 = parseCode(self.bit_reader.current, dc_params[@min(@as(usize, @intCast(self.code)), 6)]);

        self.code = @intCast(code_result_1.value);
        self.sign = @intFromBool(self.code > 0) * (self.sign ^ -(self.code & 1));

        const result_1 = self.prev_dc + (((self.code + 1) >> 1) ^ self.sign) - self.sign;
        self.slice_data[j << 6] = @floatFromInt(result_1);

        const code_result_2 = parseCode(
            self.bit_reader.current << @as(u6, @intCast(code_result_1.bits)),
            dc_params[@min(code_result_1.value, 6)],
        );

        self.code = @intCast(code_result_2.value);
        self.sign = @intFromBool(self.code > 0) * (self.sign ^ -(self.code & 1));

        const result_2 = result_1 + (((self.code + 1) >> 1) ^ self.sign) - self.sign;
        self.slice_data[(j << 6) + 64] = @floatFromInt(result_2);
        self.prev_dc = result_2;

        self.bit_reader.consume(@intCast(code_result_1.bits + code_result_2.bits));
    }
};

const AcState = struct {
    bit_reader: misc.BitReader,
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

        const run_result = parseCode(self.bit_reader.current, run_params[@min(self.run, 15)]);
        self.run = @intCast(run_result.value);
        self.pos += self.run + 1;

        const level_result = parseCode(
            self.bit_reader.current << @as(u6, @intCast(run_result.bits)),
            level_params[@min(@as(u32, @intCast(self.level)), 9)],
        );
        self.level = @as(i32, @intCast(level_result.value)) + 1;

        const j = self.pos >> self.log2_block_count;
        const total_bits = run_result.bits + level_result.bits + 1;
        const sign = -@as(i32, @intCast((self.bit_reader.current >> @as(u6, @intCast(64 - total_bits))) & 1));
        self.bit_reader.consume(@intCast(total_bits));
        self.slice_data[((self.pos & self.block_mask) << 6) + scan_order[j]] = @floatFromInt((self.level ^ sign) - sign);

        return true;
    }
};

fn parseAndStoreAlpha(
    data: []u8,
    frame_data: []u16,
    x: usize,
    y: usize,
    slice_width: usize,
    num_values: usize,
    coded_width: usize,
    comptime source_bit_depth: u64,
    comptime target_bit_depth: u64,
) void {
    var alpha_state = AlphaState(source_bit_depth, target_bit_depth).init(
        data,
        frame_data,
        x,
        y,
        slice_width,
        num_values,
        coded_width,
    );
    while (alpha_state.step()) {}
}

fn AlphaState(source_bit_depth: comptime_int, target_bit_depth: comptime_int) type {
    const mask = comptime (@as(i64, 1) << @as(u6, @intCast(source_bit_depth))) - 1;
    const signed_code_length = comptime if (source_bit_depth == 16) 7 else 4;
    const bit_difference = target_bit_depth - source_bit_depth;

    return struct {
        bit_reader: misc.BitReader,
        frame_data: []u16,
        x: usize,
        y_offset: usize,
        slice_width: usize,
        num_values: usize,
        coded_width: usize,
        pos: u32,
        alpha_val: i64,
        x_mask: usize,
        log2_slice_width: u5,

        inline fn init(data: []u8, frame_data: []u16, x: usize, y: usize, slice_width: usize, num_values: usize, coded_width: usize) @This() {
            return .{
                .bit_reader = misc.BitReader.fromData(data),
                .frame_data = frame_data,
                .x = x,
                .y_offset = y * coded_width,
                .slice_width = slice_width,
                .num_values = num_values,
                .coded_width = coded_width,
                .pos = 0,
                .alpha_val = mask,
                .x_mask = slice_width - 1,
                .log2_slice_width = std.math.log2_int(usize, slice_width),
            };
        }

        inline fn step(self: *@This()) bool {
            self.bit_reader.maybeLoadData();

            var val: i64 = undefined;

            const first_bit_not_zero = (self.bit_reader.current & comptime 1 << 63) != 0;

            if (first_bit_not_zero) {
                val = @intCast((self.bit_reader.current & comptime ~@as(u64, 1 << 63)) >> @as(u6, @intCast(63 - source_bit_depth)));
            } else {
                val = @intCast((self.bit_reader.current & comptime ~@as(u64, 1 << 63)) >> @as(u6, @intCast(63 - signed_code_length)));
                const sign = val & 1;
                val = (val + 2) >> 1;
                val = (val ^ -sign) + sign;
            }

            var bits_read = if (first_bit_not_zero) @as(u64, source_bit_depth + 1) else @as(u64, signed_code_length + 1);

            self.alpha_val = (self.alpha_val + val) & mask;

            var final_value: u16 = @intCast(self.alpha_val);
            if (bit_difference < 0) {
                final_value >>= comptime -bit_difference;
            } else {
                // Upscale by bit replication: OR the top bits back into the freed low bits so that a full-scale
                // source maps to a full-scale target
                final_value = (final_value << bit_difference) | (final_value >> comptime (source_bit_depth - bit_difference));
            }

            self.writeValue(final_value, self.pos);

            if ((self.bit_reader.current & (@as(u64, 1) << @as(u6, @intCast(63 - bits_read)))) == 0) {
                var run = (self.bit_reader.current >> @as(u6, @intCast(59 - bits_read))) & 0b1111;

                if (run == 0) {
                    run = (self.bit_reader.current >> @as(u6, @intCast(48 - bits_read))) & 0b111_1111_1111;
                    bits_read += comptime 1 + 15;
                } else {
                    bits_read += comptime 1 + 4;
                }

                const capped_run = @min(@as(u32, @intCast(run)), self.num_values - self.pos - 1);

                // +1 because of the previous write
                for (1..capped_run + 1) |i| {
                    self.writeValue(final_value, self.pos + i);
                }

                self.pos += 1 + capped_run;
            } else {
                self.pos += 1;
                bits_read += 1;
            }

            self.bit_reader.consume(bits_read);

            return self.pos < self.num_values;
        }

        inline fn writeValue(self: *@This(), value: u16, pos: u32) void {
            // Decoded alpha values are written directly into the frame data buffer
            self.frame_data[
                self.y_offset + self.coded_width * (pos >> self.log2_slice_width) +
                    self.x + (pos & self.x_mask)
            ] = value;
        }
    };
}

const ParsedCode = struct {
    value: u64,
    bits: u64,
};

inline fn parseCode(word: u64, params: u64) ParsedCode {
    const mp: u64 = params & 0b11;
    const g: u64 = (params >> 2) & 0b111;
    const r: u64 = params >> 5;

    const n: u64 = @clz(word);
    const is_big = n > mp;

    const base = @as(u64, @min(n, mp + 1)) << @as(u6, @intCast(r));

    const bits_big = (n << 1) +% g -% mp;
    const bits_small = n + 1 + r;
    const bits = if (is_big) bits_big else bits_small;
    const sub = @as(u64, 1) << (if (is_big) @intCast(g) else @intCast(r));
    const raw = word >> @as(u6, @intCast(64 - bits));

    const result = base +% raw -% sub;

    return .{
        .value = result,
        .bits = bits,
    };
}

fn transformAndStoreSliceData(
    decoder: *Decoder,
    slice_data: []const f32,
    frame_data: []u16,
    scaling_matrix_vec: @Vector(64, f32),
    slice_pos: SlicePos,
    num_blocks: u32,
    log2_blocks_per_macroblock: u32,
    comptime is_chroma: bool,
) void {
    std.debug.assert(log2_blocks_per_macroblock == 1 or log2_blocks_per_macroblock == 2);

    if (log2_blocks_per_macroblock == 2) {
        const coded_width = decoder.coded_width;

        var j: u32 = 0;
        while (j < num_blocks) : (j += 4) {
            const result_0 = idct_8x8(slice_data[(j << 6)..][0..64].*, scaling_matrix_vec);
            const result_1 = idct_8x8(slice_data[(j << 6) + 64 ..][0..64].*, scaling_matrix_vec);
            const result_2 = idct_8x8(slice_data[(j << 6) + 128 ..][0..64].*, scaling_matrix_vec);
            const result_3 = idct_8x8(slice_data[(j << 6) + 192 ..][0..64].*, scaling_matrix_vec);

            const mb_x = slice_pos.x + ((j >> 2) << 4);
            const mb_y = slice_pos.y;

            // Top-left
            storeBlock(frame_data, coded_width, result_0, mb_x, mb_y);

            // The block order is DIFFERENT for luma and chroma!! Fucky, but it is:
            if (is_chroma) {
                // Bottom-left
                storeBlock(frame_data, coded_width, result_1, mb_x, mb_y + 8);
                // Top-right
                storeBlock(frame_data, coded_width, result_2, mb_x + 8, mb_y);
            } else {
                // Top-right
                storeBlock(frame_data, coded_width, result_1, mb_x + 8, mb_y);
                // Bottom-left
                storeBlock(frame_data, coded_width, result_2, mb_x, mb_y + 8);
            }

            // Bottom-right
            storeBlock(frame_data, coded_width, result_3, mb_x + 8, mb_y + 8);
        }
    } else {
        std.debug.assert(is_chroma);
        const coded_width = decoder.coded_width >> 1;

        var j: u32 = 0;
        while (j < num_blocks) : (j += 2) {
            const result_a = idct_8x8(slice_data[(j << 6)..][0..64].*, scaling_matrix_vec);
            const result_b = idct_8x8(slice_data[(j << 6) + 64 ..][0..64].*, scaling_matrix_vec);

            const block_x = (slice_pos.x >> 1) + ((j >> 1) << 3);

            // Top
            storeBlock(frame_data, coded_width, result_a, block_x, slice_pos.y);
            // Bottom
            storeBlock(frame_data, coded_width, result_b, block_x, slice_pos.y + 8);
        }
    }
}

inline fn storeBlock(frame_data: []u16, coded_width: u32, result: [64]u16, x: u32, y: u32) void {
    inline for (0..8) |row| {
        @memcpy(
            frame_data[coded_width * (y + row) + x ..][0..8],
            result[8 * row ..][0..8],
        );
    }
}

inline fn idct_8x8(block: [64]f32, scaling_matrix: @Vector(64, f32)) [64]u16 {
    const Vec = @Vector(64, f32);
    var float_vec: Vec = block;
    float_vec *= scaling_matrix;
    float_vec[0] += comptime 4096 / (S[0] * S[0]); // Add the DC dequant offset but pre-scaled

    var rows: [8]V8 = @bitCast(float_vec);
    rows = idct_columns(rows);
    rows = transpose_rows(rows);
    rows = idct_columns(rows);

    // WASM doesn't have a neat f32->u16 instruction, so we first do f32->u32, followed by u32->u16!
    // f32->u32 already clamps the bottom at 0, so we only need to clamp the top (cheaper as int).
    var result: [64]u16 = undefined;
    inline for (0..8) |r| {
        @setRuntimeSafety(false); // Since the f32->u32 clamp is actually intended here

        var as_u32: @Vector(8, u32) = @intFromFloat(rows[r]);
        as_u32 = @min(as_u32, @as(@Vector(8, u32), @splat(1023)));

        result[8 * r ..][0..8].* = @as(@Vector(8, u16), @intCast(as_u32));
    }

    return result;
}

// Based on https://www.nayuki.io/res/fast-discrete-cosine-transform-algorithms/fast-dct-8.c
inline fn idct_columns(rows: [8]V8) [8]V8 {
    const V = V8;

    const v15: V = rows[0];
    const v26: V = rows[1];
    const v21: V = rows[2];
    const v28: V = rows[3];
    const v16: V = rows[4];
    const v25: V = rows[5];
    const v22: V = rows[6];
    const v27: V = rows[7];

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

    return .{
        v0 + v7,
        v1 + v6,
        v2 + v5,
        v3 - v4,
        v3 + v4,
        v2 - v5,
        v1 - v6,
        v0 - v7,
    };
}

const V4 = @Vector(4, f32);
const V8 = @Vector(8, f32);

// Transpose the 8 row-vectors of an 8x8 block via the 4x4-quadrant shuffle method
inline fn transpose_rows(rows: [8]V8) [8]V8 {
    var lo: [8]V4 = undefined;
    var hi: [8]V4 = undefined;
    inline for (0..8) |r| {
        lo[r] = @shuffle(f32, rows[r], undefined, [4]i32{ 0, 1, 2, 3 });
        hi[r] = @shuffle(f32, rows[r], undefined, [4]i32{ 4, 5, 6, 7 });
    }

    const a = transpose_4x4(lo[0], lo[1], lo[2], lo[3]); // out rows 0..3, cols 0..3
    const b = transpose_4x4(hi[0], hi[1], hi[2], hi[3]); // out rows 4..7, cols 0..3
    const c = transpose_4x4(lo[4], lo[5], lo[6], lo[7]); // out rows 0..3, cols 4..7
    const d = transpose_4x4(hi[4], hi[5], hi[6], hi[7]); // out rows 4..7, cols 4..7

    var result: [8]V8 = undefined;
    inline for (0..4) |i| {
        result[i] = @shuffle(f32, a[i], c[i], [8]i32{ 0, 1, 2, 3, -1, -2, -3, -4 });
        result[i + 4] = @shuffle(f32, b[i], d[i], [8]i32{ 0, 1, 2, 3, -1, -2, -3, -4 });
    }

    return result;
}

inline fn transpose_4x4(v0: V4, v1: V4, v2: V4, v3: V4) [4]V4 {
    const lo01 = @shuffle(f32, v0, v1, [4]i32{ 0, -1, 1, -2 });
    const hi01 = @shuffle(f32, v0, v1, [4]i32{ 2, -3, 3, -4 });
    const lo23 = @shuffle(f32, v2, v3, [4]i32{ 0, -1, 1, -2 });
    const hi23 = @shuffle(f32, v2, v3, [4]i32{ 2, -3, 3, -4 });

    return .{
        @shuffle(f32, lo01, lo23, [4]i32{ 0, 1, -1, -2 }),
        @shuffle(f32, lo01, lo23, [4]i32{ 2, 3, -3, -4 }),
        @shuffle(f32, hi01, hi23, [4]i32{ 0, 1, -1, -2 }),
        @shuffle(f32, hi01, hi23, [4]i32{ 2, 3, -3, -4 }),
    };
}
