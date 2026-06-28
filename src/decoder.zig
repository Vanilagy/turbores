// Copyright (c) 2026-present, Vanilagy and contributors
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const misc = @import("./misc.zig");
const gpa = misc.gpa;
const io = misc.io;
const worker = @import("./worker.zig");
const Frame = @import("./frame.zig").Frame;
const PixelFormat = @import("./frame.zig").PixelFormat;
const getYuvPixelFormat = @import("./frame.zig").getYuvPixelFormat;

const S = [_]f32{
    // The "8" bakes in three halving steps that we then don't need to do anymore in the IDCT
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

pub const DecodeTaskState = enum(u32) {
    done,
    working,
};

pub const Decoder = struct {
    concurrency: u32,
    allowed_output_formats: u32,

    packet: []u8,

    // Need two for interlaced
    pictures: [2]Picture,

    log2_chroma_blocks_per_mb: u32,
    bit_depth: u32,
    alpha_bit_depth: u32,

    luma_scaling_matrix: [64]f32,
    chroma_scaling_matrix: [64]f32,
    dc_offset: f32,

    tasks: []DecodeTask,
    running_task_count: std.atomic.Value(u32),
    task_state: std.atomic.Value(DecodeTaskState),
    worker_error: std.atomic.Value(?*worker.WorkerError),

    error_message: ?[]const u8,

    inline fn pixelFormatIsAvailable(self: *Decoder, pixel_format: PixelFormat) bool {
        return (self.allowed_output_formats & (@as(u32, 1) << @intFromEnum(pixel_format))) != 0;
    }
};

const Picture = struct {
    slice_width: u32,
    slice_info_in_row: std.MultiArrayList(SliceInfo),
    max_slice_width: u32,
    slice_sizes: []usize,
    slice_offsets: []usize,
    slice_count: u32,
    total_slice_size: usize,

    // Workers grab slices from here at runtime, so the work self-balances across them
    next_slice_index: std.atomic.Value(u32),

    // How this picture maps into the shared frame buffer (needed for interlaced)
    field_offset_rows: u32,
    row_stride_shift: u5,

    const empty = Picture{
        .slice_width = undefined,
        .slice_info_in_row = .empty,
        .max_slice_width = undefined,
        .slice_sizes = &.{},
        .slice_offsets = &.{},
        .slice_count = undefined,
        .total_slice_size = undefined,
        .next_slice_index = .init(0),
        .field_offset_rows = undefined,
        .row_stride_shift = undefined,
    };
};

const SliceInfo = struct {
    pos: u16,
    size: u8,
};

const SlicePos = struct {
    x: u32,
    y: u32,
};

pub const DecodeTask = struct {
    decoder: *Decoder,
    frame: *Frame,
    picture: *Picture,
    error_message: ?[]const u8,
};

export fn createDecoder(concurrency: u32, bit_depth: u32, allowed_output_formats: u32) ?*Decoder {
    std.debug.assert(bit_depth == 10 or bit_depth == 12);
    std.debug.assert(allowed_output_formats != 0); // Ensured by the caller

    const result = gpa.create(Decoder) catch return null;

    result.* = .{
        .concurrency = concurrency,
        .allowed_output_formats = allowed_output_formats,

        .packet = &.{},

        .pictures = .{ Picture.empty, Picture.empty },

        .log2_chroma_blocks_per_mb = undefined,
        .bit_depth = bit_depth,
        .alpha_bit_depth = undefined,

        .luma_scaling_matrix = undefined,
        .chroma_scaling_matrix = undefined,
        .dc_offset = undefined,

        .tasks = &.{},
        .running_task_count = .init(0),
        .task_state = .init(.done),
        .worker_error = .init(null),

        .error_message = null,
    };

    return result;
}

export fn getOriginalPixelFormat(decoder: *Decoder) u32 {
    return @intFromEnum(getYuvPixelFormat(
        decoder.log2_chroma_blocks_per_mb,
        decoder.bit_depth,
        decoder.alpha_bit_depth != 0,
    ));
}

export fn getErrorMessagePtr(decoder: *Decoder) ?[*]const u8 {
    return if (decoder.error_message) |msg| msg.ptr else null;
}

export fn getErrorMessageSize(decoder: *Decoder) usize {
    return if (decoder.error_message) |msg| msg.len else 0;
}

export fn closeDecoder(decoder: *Decoder) void {
    gpa.free(decoder.packet);
    for (&decoder.pictures) |*picture| {
        picture.slice_info_in_row.deinit(gpa);
        gpa.free(picture.slice_sizes);
        gpa.free(picture.slice_offsets);
    }
    gpa.free(decoder.tasks);
    gpa.destroy(decoder);
}

export fn allocatePacket(decoder: *Decoder, size: usize) ?[*]u8 {
    decoder.packet = gpa.realloc(decoder.packet, size) catch return null;
    return decoder.packet.ptr;
}

export fn getTaskStateAddress(decoder: *Decoder) *u32 {
    return @ptrCast(&decoder.task_state.raw);
}

export fn decodePacket(decoder: *Decoder, frame: *Frame) i32 {
    decodePacketInternal(decoder, frame) catch |err| return misc.toErrorCode(err);
    return 0;
}

threadlocal var error_print_buffer: [1024]u8 = undefined;

inline fn decodePacketInternal(decoder: *Decoder, frame: *Frame) misc.ConvertibleError!void {
    decoder.error_message = null;
    decoder.worker_error.store(null, .seq_cst);

    var reader = misc.ByteReader.init(decoder.packet);

    const frame_size = try reader.takeInt(u32);
    if (reader.data.len < frame_size) {
        @branchHint(.unlikely);
        decoder.error_message = "Packet is smaller than the frame size indicated in the frame header.";
        return error.InvalidData;
    }

    reader.data = decoder.packet[0..frame_size];

    const frame_type_outer = try reader.takeInt(u32);
    if (frame_type_outer != comptime std.mem.readInt(u32, "icpf", .big)) {
        @branchHint(.unlikely);
        decoder.error_message = "Invalid packet header frame type.";
        return error.InvalidData;
    }

    const header_size: u32 = try reader.takeInt(u16);

    const version = try reader.takeInt(u16);
    if (version > 1) {
        @branchHint(.unlikely);
        decoder.error_message = "Version > 1 is not supported.";
        return error.NotSupported;
    }

    _ = try reader.takeInt(u32); // Creator ID

    const frame_width = try reader.takeInt(u16);
    const frame_height = try reader.takeInt(u16);
    if (frame_width > 16384 or frame_height > 16384) {
        @branchHint(.unlikely);
        decoder.error_message = std.fmt.bufPrint(
            &error_print_buffer,
            "Frame dimensions ({}x{}) exceed the maximum supported size of 16384x16384.",
            .{ frame_width, frame_height },
        ) catch |err| switch (err) {
            error.NoSpaceLeft => return error.OutOfMemory,
        };

        return error.NotSupported;
    }

    const frame_flags = try reader.takeInt(u8);
    const frame_type = (frame_flags >> 2) & 0b11;
    if (frame_type > 2) {
        @branchHint(.unlikely);
        decoder.error_message = "Invalid frame type.";
        return error.InvalidData;
    }
    frame.scan_type = @enumFromInt(frame_type);

    const chrominance_flag = (frame_flags >> 6) & 1;
    const log2_chroma_blocks_per_mb: u32 = @intCast(chrominance_flag + 1); // 1 => 422, 2 => 444
    decoder.log2_chroma_blocks_per_mb = log2_chroma_blocks_per_mb;

    reader.toss(1); // Reserved
    frame.color_primaries = try reader.takeInt(u8);
    frame.color_transfer = try reader.takeInt(u8);
    frame.color_matrix = try reader.takeInt(u8);

    const next_byte = try reader.takeInt(u8);
    _ = next_byte >> 4; // Source pixel format
    const alpha_info = next_byte & 0b1111;
    if (alpha_info > 2) {
        @branchHint(.unlikely);
        decoder.error_message = "Invalid alpha info header field.";
        return error.InvalidData;
    }

    const alpha_bit_depth = alpha_info << 3;
    decoder.alpha_bit_depth = alpha_bit_depth;

    reader.toss(1);
    const q_mat_flags = try reader.takeInt(u8);

    const q_mat_luma: [64]u8 = if (q_mat_flags & 0b10 != 0)
        (try reader.takeArray(64)).*
    else
        @splat(4);

    const q_mat_chroma: [64]u8 = if (q_mat_flags & 0b01 != 0)
        (try reader.takeArray(64)).*
    else
        q_mat_luma; // When no chroma matrix is sent, the luma matrix is reused for chroma

    const has_alpha = alpha_bit_depth != 0;
    const actual_pixel_format = getYuvPixelFormat(
        log2_chroma_blocks_per_mb,
        decoder.bit_depth,
        has_alpha,
    );

    frame.log2_chroma_blocks_per_mb = log2_chroma_blocks_per_mb;
    frame.bit_depth = decoder.bit_depth;
    frame.alpha_bit_depth = alpha_bit_depth;

    if (!decoder.pixelFormatIsAvailable(actual_pixel_format)) blk: {
        const alpha_states = [_]bool{ false, true };
        const chroma_subsamplings = [_]u32{ 0, 1, 2 };
        const bit_depths = [_]u32{ 8, 10, 12 };
        const new_alpha_bit_depth: i32 = if (alpha_bit_depth != 0) alpha_bit_depth else -1;

        // Try to find a *better* format to convert to, losslessly
        for (alpha_states) |has_alpha_2| {
            for (chroma_subsamplings) |log2_chroma_blocks_per_mb_2| {
                for (bit_depths) |bit_depth_2| {
                    const is_worse = @intFromBool(has_alpha_2) < @intFromBool(has_alpha) or
                        log2_chroma_blocks_per_mb_2 < log2_chroma_blocks_per_mb or
                        bit_depth_2 < decoder.bit_depth;
                    if (is_worse) {
                        continue;
                    }

                    const pixel_format = getYuvPixelFormat(
                        log2_chroma_blocks_per_mb_2,
                        bit_depth_2,
                        has_alpha_2,
                    );
                    if (decoder.pixelFormatIsAvailable(pixel_format)) {
                        frame.log2_chroma_blocks_per_mb = log2_chroma_blocks_per_mb_2;
                        frame.alpha_bit_depth = if (has_alpha_2) new_alpha_bit_depth else 0;
                        frame.bit_depth = bit_depth_2;

                        break :blk;
                    }
                }
            }
        }

        // We must throw away some data, so find the least-bad worse format
        for ([_]bool{ false, true }) |has_alpha_is_different| {
            const has_alpha_2 = has_alpha != has_alpha_is_different; // != is xor here

            for (misc.arrayReverse(bit_depths)) |bit_depth_2| {
                for (misc.arrayReverse(chroma_subsamplings)) |log2_chroma_blocks_per_mb_2| {
                    const pixel_format = getYuvPixelFormat(
                        log2_chroma_blocks_per_mb_2,
                        bit_depth_2,
                        has_alpha_2,
                    );
                    if (decoder.pixelFormatIsAvailable(pixel_format)) {
                        frame.log2_chroma_blocks_per_mb = log2_chroma_blocks_per_mb_2;
                        frame.alpha_bit_depth = if (has_alpha_2) new_alpha_bit_depth else 0;
                        frame.bit_depth = bit_depth_2;

                        break :blk;
                    }
                }
            }
        }
    }

    // To achieve the desired output bit depth, we must derive a scaling factor for it
    const output_value_scaling = if (frame.bit_depth >= decoder.bit_depth)
        @as(f32, @floatFromInt(@as(u32, 1) << @as(u5, @intCast(frame.bit_depth - decoder.bit_depth))))
    else
        1 / @as(f32, @floatFromInt(@as(u32, 1) << @as(u5, @intCast(decoder.bit_depth - frame.bit_depth))));
    decoder.dc_offset = output_value_scaling * (comptime 4096 / (S[0] * S[0]));

    // Fold the dequantization, AAN scaling factors and bit depth scaling into a single matrix
    inline for (0..8) |x| {
        inline for (0..8) |y| {
            const i = 8 * y + x;
            decoder.luma_scaling_matrix[i] = @floatFromInt(q_mat_luma[8 * x + y]); // Read the matrix transposed-ly
            decoder.luma_scaling_matrix[i] *= 0.25; // >> 2
            decoder.luma_scaling_matrix[i] *= comptime 1 / (S[x] * S[y]);
            decoder.luma_scaling_matrix[i] *= output_value_scaling;
        }
    }

    inline for (0..8) |x| {
        inline for (0..8) |y| {
            const i = 8 * y + x;
            decoder.chroma_scaling_matrix[i] = @floatFromInt(q_mat_chroma[8 * x + y]); // Read the matrix transposed-ly
            decoder.chroma_scaling_matrix[i] *= 0.25; // >> 2
            decoder.chroma_scaling_matrix[i] *= comptime 1 / (S[x] * S[y]);
            decoder.chroma_scaling_matrix[i] *= output_value_scaling;
        }
    }

    const is_interlaced = frame_type != 0;
    const picture_count: u32 = if (is_interlaced) 2 else 1;
    const row_stride_shift: u5 = if (is_interlaced) 1 else 0;

    frame.visible_width = frame_width;
    frame.visible_height = frame_height;

    frame.coded_width = (frame_width + 15) & ~@as(u32, 15);
    if (is_interlaced) {
        const field_visible_height = (frame_height + 1) >> 1;
        const field_coded_height = (field_visible_height + 15) & ~@as(u32, 15);
        frame.coded_height = field_coded_height << 1;
    } else {
        frame.coded_height = (frame_height + 15) & ~@as(u32, 15);
    }

    const luma_data_size = frame.coded_width * frame.coded_height;
    var frame_data_size = luma_data_size;
    if (frame.log2_chroma_blocks_per_mb == 0) {
        frame_data_size += frame_data_size >> 1;
    } else {
        frame_data_size *= frame.log2_chroma_blocks_per_mb + 1;
    }

    if (frame.alpha_bit_depth != 0) {
        frame_data_size += luma_data_size;
    }

    const bytes_per_sample = (frame.bit_depth + 7) >> 3;
    frame_data_size *= bytes_per_sample;

    frame.frame_data = try gpa.realloc(frame.frame_data, frame_data_size);

    if (8 + header_size < reader.pos) {
        @branchHint(.unlikely);
        decoder.error_message = "Frame header size too small.";
        return error.InvalidData;
    }

    reader.pos = 8 + header_size;

    const field_coded_height = frame.coded_height >> row_stride_shift;
    const first_field_offset: u32 = if (frame_type == 2) 1 else 0;

    for (0..picture_count) |i| {
        const field_offset_rows: u32 = if (i == 0) first_field_offset else 1 - first_field_offset;

        try parsePicture(
            decoder,
            frame,
            &reader,
            field_coded_height,
            &decoder.pictures[i],
            field_offset_rows,
            row_stride_shift,
        );
    }

    if (decoder.concurrency == 0) {
        // Synchronous, just decode right here right now
        decoder.tasks = try gpa.realloc(decoder.tasks, picture_count);
        for (0..picture_count) |p| {
            const picture = &decoder.pictures[p];
            picture.next_slice_index.store(0, .seq_cst);

            decoder.tasks[p] = .{
                .decoder = decoder,
                .frame = frame,
                .picture = picture,
                .error_message = null,
            };

            const task = &decoder.tasks[p];
            executeDecodeTask(task) catch |err| {
                decoder.error_message = task.error_message;
                return err;
            };
        }

        return;
    }

    misc.lockMutex(&worker.worker_task_queue_mutex);
    defer worker.worker_task_queue_mutex.unlock(io);

    const task_count_per_picture = decoder.concurrency;
    const total_task_count = picture_count * task_count_per_picture;
    decoder.tasks = try gpa.realloc(decoder.tasks, total_task_count);

    var task_index: usize = 0;
    for (0..picture_count) |p| {
        const picture = &decoder.pictures[p];
        picture.next_slice_index.store(0, .seq_cst);

        for (0..task_count_per_picture) |_| {
            decoder.tasks[task_index] = .{
                .decoder = decoder,
                .frame = frame,
                .picture = picture,
                .error_message = null,
            };

            try worker.worker_task_queue.pushBack(gpa, .{
                .decode = &decoder.tasks[task_index],
            });
            task_index += 1;
        }
    }

    decoder.task_state.store(.working, .seq_cst);
    io.futexWake(u32, &worker.worker_task_queue.len, total_task_count);

    decoder.running_task_count.store(total_task_count, .seq_cst);
}

fn parsePicture(
    decoder: *Decoder,
    frame: *Frame,
    outside_reader: *misc.ByteReader,
    field_coded_height: u32,
    picture: *Picture,
    field_offset_rows: u32,
    row_stride_shift: u5,
) !void {
    var reader = outside_reader.*;

    const pic_header_start_pos = reader.pos;
    const pic_header_size: u32 = try reader.takeInt(u8) >> 3;
    const pic_data_size = try reader.takeInt(u32);

    // Protect against overflow
    const pic_data_end = try std.math.add(u32, pic_header_start_pos, pic_data_size);

    if (reader.data.len < pic_data_end) {
        @branchHint(.unlikely);
        decoder.error_message = "Packet is smaller than the picture data size indicated in the picture header.";
        return error.InvalidData;
    }

    reader.data = reader.data[0..pic_data_end];

    const total_slices: u32 = try reader.takeInt(u16);
    const slice_dimensions = try reader.takeInt(u8);

    if (pic_header_start_pos + pic_header_size < reader.pos) {
        @branchHint(.unlikely);
        decoder.error_message = "Picture header size too small.";
        return error.InvalidData;
    }

    reader.pos = pic_header_start_pos + pic_header_size;

    const log2_slice_width = slice_dimensions >> 4;
    if (log2_slice_width > 7) {
        @branchHint(.unlikely);
        // Slice widths are stored in a u8 down the line, so 128 (1 << 7) is the largest we can represent
        decoder.error_message = "Slice widths larger than 128 are not supported.";
        return error.NotSupported;
    }
    picture.slice_width = @as(u32, 1) << @as(u5, @intCast(log2_slice_width));

    const log2_slice_height = slice_dimensions & 0b1111;
    if (log2_slice_height > 0) {
        @branchHint(.unlikely);
        // Apparently all other decoders only support this value, and therefore no encoder emits anything but this
        // value, so we can hardcode it to simplify the code.
        decoder.error_message = "Only slice heights of 1 are supported.";
        return error.NotSupported;
    }

    picture.slice_info_in_row.clearRetainingCapacity();
    picture.max_slice_width = 0;

    var current_x: u16 = 0;
    const coded_width_in_macroblocks = frame.coded_width >> 4;
    while (current_x < coded_width_in_macroblocks) {
        var width: u8 = @intCast(picture.slice_width);
        while (current_x + width > coded_width_in_macroblocks) {
            width >>= 1;
        }

        try picture.slice_info_in_row.append(gpa, .{
            .pos = current_x,
            .size = width,
        });
        current_x += width;

        if (picture.max_slice_width == 0) {
            // The first slice has the maximum width (no other slice has a longer width)
            picture.max_slice_width = width;
        }
    }

    const expected_slice_count = picture.slice_info_in_row.len * (field_coded_height >> 4);
    if (total_slices != expected_slice_count) {
        @branchHint(.unlikely);
        decoder.error_message = std.fmt.bufPrint(
            &error_print_buffer,
            "Unexpected slice count: expected {}, found {}.",
            .{ expected_slice_count, total_slices },
        ) catch |err| switch (err) {
            error.NoSpaceLeft => return error.OutOfMemory,
        };

        return error.InvalidData;
    }

    var total_slice_size: usize = 0;
    picture.slice_sizes = try gpa.realloc(picture.slice_sizes, total_slices);
    for (0..total_slices) |i| {
        const size: usize = try reader.takeInt(u16);

        picture.slice_sizes[i] = size;
        total_slice_size += size;
    }

    picture.slice_offsets = try gpa.realloc(picture.slice_offsets, total_slices);

    var current_offset: usize = reader.pos;
    for (0..total_slices) |i| {
        picture.slice_offsets[i] = current_offset;

        // Protect against overflow
        current_offset = try std.math.add(usize, current_offset, picture.slice_sizes[i]);
    }

    if (current_offset > reader.data.len) {
        @branchHint(.unlikely);
        decoder.error_message = "Slice data extends past the bounds of the picture data.";
        return error.UnexpectedEof;
    }

    picture.slice_count = total_slices;
    picture.total_slice_size = total_slice_size;
    picture.field_offset_rows = field_offset_rows;
    picture.row_stride_shift = row_stride_shift;

    outside_reader.pos = pic_data_end;
}

export fn finalizePacketDecoding(decoder: *Decoder) i32 {
    if (decoder.running_task_count.load(.seq_cst) > 0) {
        @branchHint(.unlikely);
        // Shouldn't be possible to get into this state; bad bad!
        return comptime misc.toErrorCode(error.InvalidState);
    }

    const worker_error_maybe = decoder.worker_error.load(.seq_cst);
    if (worker_error_maybe) |worker_error| {
        @branchHint(.unlikely);
        decoder.error_message = worker_error.message;
        return worker_error.code;
    }

    return 0;
}

pub fn executeDecodeTask(task: *DecodeTask) !void {
    const decoder = task.decoder;
    const frame = task.frame;
    const picture = task.picture;
    const slice_count = picture.slice_count;

    const field_offset_rows = picture.field_offset_rows;
    const row_stride_shift = picture.row_stride_shift;

    // Scan order depends on scan type
    const scan_table = if (row_stride_shift != 0)
        &interlaced_scan_order
    else
        &progressive_scan_order;

    var reader = misc.ByteReader.init(decoder.packet);

    const max_num_luma_blocks = picture.max_slice_width << 2;
    const max_num_chroma_blocks = picture.max_slice_width << @as(u5, @intCast(decoder.log2_chroma_blocks_per_mb));

    const max_luma_slice_len = max_num_luma_blocks << 6;
    const max_chroma_slice_len = max_num_chroma_blocks << 6;

    const luma_scaling_matrix = decoder.luma_scaling_matrix;
    const chroma_scaling_matrix = decoder.chroma_scaling_matrix;

    const frame_data = frame.frame_data;
    const bytes_per_sample = (frame.bit_depth + 7) >> 3;
    const chroma_entries = (frame.coded_width * frame.coded_height) >> @as(u5, @intCast(2 - frame.log2_chroma_blocks_per_mb));
    const chroma_width = if (frame.log2_chroma_blocks_per_mb == 2) frame.coded_width else frame.coded_width >> 1;

    const luma_plane_start = 0;
    const u_plane_start = bytes_per_sample * frame.coded_width * frame.coded_height;
    const v_plane_start = bytes_per_sample * (frame.coded_width * frame.coded_height + chroma_entries);
    const alpha_plane_start = bytes_per_sample * (frame.coded_width * frame.coded_height + (chroma_entries << 1));

    // The field starts at this row within each plane
    const luma_field_byte_offset = bytes_per_sample * field_offset_rows * frame.coded_width;
    const chroma_field_byte_offset = bytes_per_sample * field_offset_rows * chroma_width;

    // The alignment guarantees are provided by the coded dimensions always being a multiple of 16
    const luma_frame_data: []align(2) u8 =
        @alignCast(frame_data[luma_plane_start + luma_field_byte_offset .. u_plane_start]);
    const u_frame_data: []align(2) u8 =
        @alignCast(frame_data[u_plane_start + chroma_field_byte_offset .. v_plane_start]);
    const v_frame_data: []align(2) u8 =
        @alignCast(frame_data[v_plane_start + chroma_field_byte_offset .. alpha_plane_start]);
    const alpha_frame_data: []align(2) u8 =
        @alignCast(frame_data[alpha_plane_start + (if (frame.alpha_bit_depth > 0) luma_field_byte_offset else 0) ..]);

    // Aligned for SIMD access
    const slice_data = try gpa.alignedAlloc(f32, .@"16", (max_luma_slice_len + (max_chroma_slice_len << 1)) << 1);
    defer gpa.free(slice_data);

    const slice_1_luma_data = slice_data[0..max_luma_slice_len];
    const slice_2_luma_data = slice_data[max_luma_slice_len..][0..max_luma_slice_len];
    const slice_1_u_data = slice_data[(max_luma_slice_len << 1)..][0..max_chroma_slice_len];
    const slice_2_u_data = slice_data[(max_luma_slice_len << 1) + 1 * max_chroma_slice_len ..][0..max_chroma_slice_len];
    const slice_1_v_data = slice_data[(max_luma_slice_len << 1) + 2 * max_chroma_slice_len ..][0..max_chroma_slice_len];
    const slice_2_v_data = slice_data[(max_luma_slice_len << 1) + 3 * max_chroma_slice_len ..][0..max_chroma_slice_len];

    const has_alpha_to_parse = frame.alpha_bit_depth > 0;

    if (frame.alpha_bit_depth == -1 and &decoder.tasks[decoder.tasks.len - 1] == task) {
        // We need to fill the alpha data with the opaque value. This only need to be done once, so arbitrarily, we
        // delegate this job to the last decode task (in the assumption that it usually has the least work to do).
        switch (frame.bit_depth) {
            8 => {
                @memset(alpha_frame_data, 255);
            },
            10, 12 => {
                // @memset would be terribly slow here since it's a two-byte pattern, so do some @memcpy-ing instead
                const chunk_size = 8192;

                // memset-fill a short initial segment with the byte pattern
                const shorts = std.mem.bytesAsSlice(u16, alpha_frame_data);
                const start = shorts[0..@min(chunk_size, shorts.len)];
                const fill_value = (@as(u16, 1) << @as(u4, @intCast(frame.bit_depth))) - 1;
                @memset(start, fill_value);

                // Copy the initial segment to fill the rest of the bytes
                var offset: usize = chunk_size;
                while (offset + (chunk_size - 1) < shorts.len) : (offset += chunk_size) {
                    const chunk = shorts[offset..][0..chunk_size];
                    @memcpy(chunk, start);
                }

                // Take care of any remainder
                if (offset < shorts.len) {
                    const chunk = shorts[offset..];
                    @memcpy(chunk, start[0..chunk.len]);
                }
            },
            else => unreachable,
        }
    }

    // Grab slice pairs from the picture's shared cursor until it's drained
    while (true) {
        const base = picture.next_slice_index.fetchAdd(2, .seq_cst);
        if (base >= slice_count) {
            break;
        }

        if (base + 1 == slice_count) {
            // Only a single slice left; decode it on its own
            reader.pos = picture.slice_offsets[base];
            const header = try parseSliceHeader(task, &reader, base);

            const num_luma_blocks = header.width_mb << 2;
            const num_chroma_blocks = header.width_mb << @as(u5, @intCast(decoder.log2_chroma_blocks_per_mb));
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
            try parseDcAndAcSingle(header.luma_data, luma_data, num_luma_blocks, task, scan_table);
            transformAndStoreSliceData(
                task,
                luma_data,
                luma_frame_data,
                luma_vec,
                pos,
                num_luma_blocks,
                2,
                2,
                false,
                bytes_per_sample,
                row_stride_shift,
            );

            // U
            try parseDcAndAcSingle(header.u_data, u_data, num_chroma_blocks, task, scan_table);
            transformAndStoreSliceData(
                task,
                u_data,
                u_frame_data,
                chroma_vec,
                pos,
                num_chroma_blocks,
                decoder.log2_chroma_blocks_per_mb,
                frame.log2_chroma_blocks_per_mb,
                true,
                bytes_per_sample,
                row_stride_shift,
            );

            // V
            try parseDcAndAcSingle(header.v_data, v_data, num_chroma_blocks, task, scan_table);
            transformAndStoreSliceData(
                task,
                v_data,
                v_frame_data,
                chroma_vec,
                pos,
                num_chroma_blocks,
                decoder.log2_chroma_blocks_per_mb,
                frame.log2_chroma_blocks_per_mb,
                true,
                bytes_per_sample,
                row_stride_shift,
            );

            if (has_alpha_to_parse) {
                switch (frame.alpha_bit_depth) {
                    inline 8, 16 => |source_bit_depth| {
                        switch (frame.bit_depth) {
                            inline 8, 10, 12 => |target_bit_depth| {
                                parseAndStoreAlpha(
                                    header.alpha_data,
                                    alpha_frame_data,
                                    pos.x,
                                    pos.y,
                                    header.width_mb << 4,
                                    num_luma_blocks << 6,
                                    frame.coded_width << row_stride_shift,
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

            break;
        }

        reader.pos = picture.slice_offsets[base];
        const header_1 = try parseSliceHeader(task, &reader, base);
        reader.pos = picture.slice_offsets[base + 1];
        const header_2 = try parseSliceHeader(task, &reader, base + 1);

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
        const num_chroma_blocks_1 = header_1.width_mb << @as(u5, @intCast(decoder.log2_chroma_blocks_per_mb));
        const num_chroma_blocks_2 = header_2.width_mb << @as(u5, @intCast(decoder.log2_chroma_blocks_per_mb));

        // Luma for slice 1 and 2
        try parseDcAndAcPair(
            header_1.luma_data,
            header_2.luma_data,
            slice_1_luma_data,
            slice_2_luma_data,
            num_luma_blocks_1,
            num_luma_blocks_2,
            task,
            scan_table,
        );
        transformAndStoreSliceData(
            task,
            slice_1_luma_data,
            luma_frame_data,
            luma_vec_1,
            pos_1,
            num_luma_blocks_1,
            2,
            2,
            false,
            bytes_per_sample,
            row_stride_shift,
        );
        transformAndStoreSliceData(
            task,
            slice_2_luma_data,
            luma_frame_data,
            luma_vec_2,
            pos_2,
            num_luma_blocks_2,
            2,
            2,
            false,
            bytes_per_sample,
            row_stride_shift,
        );

        // U for slice 1 and 2
        try parseDcAndAcPair(
            header_1.u_data,
            header_2.u_data,
            slice_1_u_data,
            slice_2_u_data,
            num_chroma_blocks_1,
            num_chroma_blocks_2,
            task,
            scan_table,
        );
        transformAndStoreSliceData(
            task,
            slice_1_u_data,
            u_frame_data,
            chroma_vec_1,
            pos_1,
            num_chroma_blocks_1,
            decoder.log2_chroma_blocks_per_mb,
            frame.log2_chroma_blocks_per_mb,
            true,
            bytes_per_sample,
            row_stride_shift,
        );
        transformAndStoreSliceData(
            task,
            slice_2_u_data,
            u_frame_data,
            chroma_vec_2,
            pos_2,
            num_chroma_blocks_2,
            decoder.log2_chroma_blocks_per_mb,
            frame.log2_chroma_blocks_per_mb,
            true,
            bytes_per_sample,
            row_stride_shift,
        );

        // V for slice 1 and 2
        try parseDcAndAcPair(
            header_1.v_data,
            header_2.v_data,
            slice_1_v_data,
            slice_2_v_data,
            num_chroma_blocks_1,
            num_chroma_blocks_2,
            task,
            scan_table,
        );
        transformAndStoreSliceData(
            task,
            slice_1_v_data,
            v_frame_data,
            chroma_vec_1,
            pos_1,
            num_chroma_blocks_1,
            decoder.log2_chroma_blocks_per_mb,
            frame.log2_chroma_blocks_per_mb,
            true,
            bytes_per_sample,
            row_stride_shift,
        );
        transformAndStoreSliceData(
            task,
            slice_2_v_data,
            v_frame_data,
            chroma_vec_2,
            pos_2,
            num_chroma_blocks_2,
            decoder.log2_chroma_blocks_per_mb,
            frame.log2_chroma_blocks_per_mb,
            true,
            bytes_per_sample,
            row_stride_shift,
        );

        if (has_alpha_to_parse) {
            switch (frame.alpha_bit_depth) {
                inline 8, 16 => |source_bit_depth| {
                    switch (frame.bit_depth) {
                        inline 8, 10, 12 => |target_bit_depth| {
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
                                frame.coded_width << row_stride_shift,
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
                                frame.coded_width << row_stride_shift,
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

inline fn parseSliceHeader(task: *DecodeTask, reader: *misc.ByteReader, i: usize) !SliceHeader {
    // We can do unchecked reads here because we have already verified that the slice data fits

    const picture = task.picture;
    const start_pos = reader.pos;
    const slice_size = picture.slice_sizes[i];
    const slice_header_size: u32 = try reader.takeInt(u8) >> 3;

    var scale_factor: u32 = std.math.clamp(try reader.takeInt(u8), 1, 224);
    if (scale_factor > 128) {
        scale_factor = (scale_factor - 96) << 2;
    }

    const luma_data_size: u32 = try reader.takeInt(u16);
    const u_data_size: u32 = try reader.takeInt(u16);

    const size_until_v = slice_header_size + luma_data_size + u_data_size;
    if (size_until_v > slice_size) {
        @branchHint(.unlikely);
        task.error_message = "Channel data planes too large to fit into slice data.";
        return error.InvalidData;
    }

    const v_data_size: u32 = if (slice_header_size >= 8)
        try reader.takeInt(u16) // There's a special field for V data size
    else
        slice_size - size_until_v;

    const size_until_alpha = size_until_v + v_data_size;
    if (size_until_alpha > slice_size) {
        @branchHint(.unlikely);
        task.error_message = "Channel data planes too large to fit into slice data.";
        return error.InvalidData;
    }

    const alpha_data_size = slice_size - size_until_alpha; // This is 0 for non-alpha frames

    if (start_pos + slice_header_size < reader.pos) {
        @branchHint(.unlikely);
        task.error_message = "Slice header size too small.";
        return error.InvalidData;
    }
    reader.pos = start_pos + slice_header_size;

    // Unchecked because bounds were verified above
    const luma_data = reader.takeUnchecked(luma_data_size);
    const u_data = reader.takeUnchecked(u_data_size);
    const v_data = reader.takeUnchecked(v_data_size);
    const alpha_data = reader.takeUnchecked(alpha_data_size);

    const y_index = i / picture.slice_info_in_row.len;
    const x_index = i - y_index * picture.slice_info_in_row.len; // No % so we don't need two int divisions

    return .{
        .scale_factor = scale_factor,
        .luma_data = luma_data,
        .u_data = u_data,
        .v_data = v_data,
        .alpha_data = alpha_data,
        .width_mb = picture.slice_info_in_row.items(.size)[x_index],
        .pos_x_mb = picture.slice_info_in_row.items(.pos)[x_index],
        .pos_y_mb = y_index,
    };
}

const progressive_scan_order = transpose_scan_values(.{
    0,  1,  8,  9,  2,  3,  10, 11,
    16, 17, 24, 25, 18, 19, 26, 27,
    4,  5,  12, 20, 13, 6,  7,  14,
    21, 28, 29, 22, 15, 23, 30, 31,
    32, 33, 40, 48, 41, 34, 35, 42,
    49, 56, 57, 50, 43, 36, 37, 44,
    51, 58, 59, 52, 45, 38, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
});
const interlaced_scan_order = transpose_scan_values(.{
    0,  8,  1,  9,  16, 24, 17, 25,
    2,  10, 3,  11, 18, 26, 19, 27,
    32, 40, 33, 34, 41, 48, 56, 49,
    42, 35, 43, 50, 57, 58, 51, 59,
    4,  12, 5,  6,  13, 20, 28, 21,
    14, 7,  15, 22, 29, 36, 44, 37,
    30, 23, 31, 38, 45, 52, 60, 53,
    46, 39, 47, 54, 61, 62, 55, 63,
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
    task: *DecodeTask,
    scan_table: *const [64]u8,
) !void {
    // Special logic in case the data is empty (which is handled gracefully)
    if (data_1.len == 0 or data_2.len == 0) {
        @branchHint(.unlikely);

        if (data_1.len != 0) {
            return parseDcAndAcSingle(data_1, slice_1_data, num_blocks_1, task, scan_table);
        } else {
            return parseDcAndAcSingle(data_2, slice_2_data, num_blocks_2, task, scan_table);
        }
    }

    // Pre-set the error message in case DC fails
    task.error_message = "Invalid DC code stream.";

    var dc_state_1 = try DcState.init(data_1, slice_1_data);
    var dc_state_2 = try DcState.init(data_2, slice_2_data);

    var j: u32 = 2;
    const min_num_blocks = @min(num_blocks_1, num_blocks_2);
    while (j < min_num_blocks) : (j += 2) {
        try dc_state_1.step(j);
        try dc_state_2.step(j);
    }
    while (j < num_blocks_1) : (j += 2) try dc_state_1.step(j);
    while (j < num_blocks_2) : (j += 2) try dc_state_2.step(j);

    // Pre-set the error message in case AC fails
    task.error_message = "Invalid AC code stream.";

    const log2_block_count_1: u5 = @intCast(std.math.log2_int(u32, num_blocks_1));
    const log2_block_count_2: u5 = @intCast(std.math.log2_int(u32, num_blocks_2));
    const block_mask_1 = num_blocks_1 - 1;
    const block_mask_2 = num_blocks_2 - 1;

    var ac_state_1 = AcState{
        .bit_reader = dc_state_1.bit_reader,
        .slice_data = slice_1_data,
        .pos = block_mask_1,
        .log2_block_count = log2_block_count_1,
        .num_coefficients = @as(u32, 64) << log2_block_count_1,
        .block_mask = block_mask_1,
        .scan_order = scan_table,
    };
    var ac_state_2 = AcState{
        .bit_reader = dc_state_2.bit_reader,
        .slice_data = slice_2_data,
        .pos = block_mask_2,
        .log2_block_count = log2_block_count_2,
        .num_coefficients = @as(u32, 64) << log2_block_count_2,
        .block_mask = block_mask_2,
        .scan_order = scan_table,
    };

    var active_1 = true;
    var active_2 = true;
    while (active_1 and active_2) {
        active_1 = try ac_state_1.step();
        active_2 = try ac_state_2.step();
    }
    while (active_1) active_1 = try ac_state_1.step();
    while (active_2) active_2 = try ac_state_2.step();

    // We got through; no error message!
    task.error_message = null;
}

fn parseDcAndAcSingle(data: []u8, slice_data: []f32, num_blocks: u32, task: *DecodeTask, scan_table: *const [64]u8) !void {
    // An empty scan carries no coefficients; the slice data is already zeroed, so there's nothing to do.
    if (data.len == 0) {
        @branchHint(.unlikely);
        return;
    }

    // Pre-set the error message in case DC fails
    task.error_message = "Invalid DC code stream.";

    var dc_state = try DcState.init(data, slice_data);

    var j: u32 = 2;
    while (j < num_blocks) : (j += 2) {
        try dc_state.step(j);
    }

    // Pre-set the error message in case AC fails
    task.error_message = "Invalid AC code stream.";

    const log2_block_count: u5 = @intCast(std.math.log2_int(u32, num_blocks));
    const block_mask = num_blocks - 1;

    var ac_state = AcState{
        .bit_reader = dc_state.bit_reader,
        .slice_data = slice_data,
        .pos = block_mask,
        .log2_block_count = log2_block_count,
        .num_coefficients = @as(u32, 64) << log2_block_count,
        .block_mask = block_mask,
        .scan_order = scan_table,
    };

    while (try ac_state.step()) {}

    // We got through; no error message!
    task.error_message = null;
}

const DcState = struct {
    bit_reader: misc.BitReader,
    slice_data: []f32,
    code: i32,
    sign: i32,
    prev_dc: i32,

    inline fn init(data: []u8, slice_data: []f32) !DcState {
        var s = DcState{
            .bit_reader = misc.BitReader.fromData(data),
            .slice_data = slice_data,
            .code = undefined,
            .sign = undefined,
            .prev_dc = undefined,
        };

        s.bit_reader.maybeLoadData();

        const first_code_result = try parseCode(s.bit_reader.current, 0xb8);
        s.code = @intCast(first_code_result.value);

        const first_dc = (s.code >> 1) ^ -(s.code & 1);
        s.slice_data[0] = @floatFromInt(first_dc);
        s.prev_dc = first_dc;

        const second_code_result = try parseCode(
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

    inline fn step(self: *DcState, j: usize) !void {
        self.bit_reader.maybeLoadData();

        const code_result_1 = try parseCode(
            self.bit_reader.current,
            dc_params[@min(@as(usize, @intCast(self.code)), 6)],
        );

        self.code = @intCast(code_result_1.value);
        self.sign = @intFromBool(self.code > 0) * (self.sign ^ -(self.code & 1));

        const result_1 = self.prev_dc + (((self.code + 1) >> 1) ^ self.sign) - self.sign;
        self.slice_data[j << 6] = @floatFromInt(result_1);

        const next_current = self.bit_reader.current << @as(u6, @intCast(code_result_1.bits));
        const code_result_2 = try parseCode(
            next_current,
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
    num_coefficients: u32,
    block_mask: u32,
    scan_order: *const [64]u8,
    run: u32 = 4,
    level: i32 = 2,

    inline fn step(self: *AcState) !bool {
        self.bit_reader.maybeLoadData();
        if (self.bit_reader.current == 0) {
            return false;
        }

        const run_result = try parseCode(
            self.bit_reader.current,
            run_params[@min(self.run, 15)],
        );
        self.run = @intCast(run_result.value);
        self.pos += self.run + 1;

        if (self.pos >= self.num_coefficients) {
            @branchHint(.unlikely);
            return error.InvalidData;
        }

        const level_result = try parseCode(
            self.bit_reader.current << @as(u6, @intCast(run_result.bits)),
            level_params[@min(@as(u32, @intCast(self.level)), 9)],
        );
        self.level = @as(i32, @intCast(level_result.value)) + 1;

        const j = self.pos >> self.log2_block_count;
        const total_bits = run_result.bits + level_result.bits + 1;
        const sign = -@as(i32, @intCast((self.bit_reader.current >> @as(u6, @intCast(64 - total_bits))) & 1));
        self.bit_reader.consume(@intCast(total_bits));
        self.slice_data[((self.pos & self.block_mask) << 6) + self.scan_order[j]] = @floatFromInt((self.level ^ sign) - sign);

        return true;
    }
};

fn parseAndStoreAlpha(
    data: []u8,
    frame_data: []align(2) u8,
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
    const ElementType = if (target_bit_depth == 8) u8 else u16;

    return struct {
        bit_reader: misc.BitReader,
        frame_data: []ElementType,
        x: usize,
        y_offset: usize,
        slice_width: usize,
        num_values: usize,
        coded_width: usize,
        pos: u32,
        alpha_val: i64,
        x_mask: usize,
        log2_slice_width: u5,

        inline fn init(data: []u8, frame_data: []align(2) u8, x: usize, y: usize, slice_width: usize, num_values: usize, coded_width: usize) @This() {
            return .{
                .bit_reader = misc.BitReader.fromData(data),
                .frame_data = std.mem.bytesAsSlice(ElementType, frame_data),
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
            // No error handling in here because it can't fail; if the bitstream is too short, it will still parse
            // properly because it's just going to parse a bunch of zeroes.

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
            } else if (bit_difference > 0) {
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
            ] = @intCast(value);
        }
    };
}

const ParsedCode = struct {
    value: u64,
    bits: u64,
};

inline fn parseCode(word: u64, params: u64) !ParsedCode {
    const mp: u64 = params & 0b11;
    const g: u64 = (params >> 2) & 0b111;
    const r: u64 = params >> 5;

    const n: u64 = @clz(word);
    const is_big = n > mp;

    const base = @as(u64, @min(n, mp + 1)) << @as(u6, @intCast(r));

    const bits_big = (n << 1) +% g -% mp;
    const bits_small = n + 1 + r;
    const bits = if (is_big) bits_big else bits_small;

    if (bits > 31) {
        @branchHint(.unlikely);
        return error.InvalidData;
    }

    const sub = @as(u64, 1) << (if (is_big) @intCast(g) else @intCast(r));
    const raw = word >> @as(u6, @intCast(64 - bits));

    const result = base +% raw -% sub;

    return .{
        .value = result,
        .bits = bits,
    };
}

inline fn transformAndStoreSliceData(
    task: *DecodeTask,
    slice_data: []const f32,
    frame_data: []align(2) u8,
    scaling_matrix_vec: @Vector(64, f32),
    slice_pos: SlicePos,
    num_blocks: u32,
    source_log2_blocks_per_macroblock: u32,
    target_log2_block_per_macroblock: u32,
    is_chroma: bool,
    bytes_per_sample: u32,
    row_stride_shift: u5,
) void {
    // Based on the incoming parameters, dispatch to the correct baked function
    switch (bytes_per_sample) {
        inline 1, 2 => |bytes_per_sample_captured| {
            switch (source_log2_blocks_per_macroblock) {
                inline 1, 2 => |source_log2_blocks_per_macroblock_captured| {
                    switch (target_log2_block_per_macroblock) {
                        inline 0, 1, 2 => |target_log2_block_per_macroblock_captured| {
                            transformAndStoreSliceDataBaked(
                                task,
                                slice_data,
                                frame_data,
                                scaling_matrix_vec,
                                slice_pos,
                                num_blocks,
                                source_log2_blocks_per_macroblock_captured,
                                target_log2_block_per_macroblock_captured,
                                is_chroma,
                                bytes_per_sample_captured,
                                row_stride_shift,
                            );
                        },
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

noinline fn transformAndStoreSliceDataBaked(
    task: *DecodeTask,
    slice_data: []const f32,
    frame_data: []align(2) u8,
    scaling_matrix_vec: @Vector(64, f32),
    slice_pos: SlicePos,
    num_blocks: u32,
    comptime source_log2_blocks_per_macroblock: u32,
    comptime target_log2_block_per_macroblock: u32,
    is_chroma: bool,
    comptime bytes_per_sample: u32,
    row_stride_shift: u5,
) void {
    std.debug.assert(source_log2_blocks_per_macroblock == 1 or source_log2_blocks_per_macroblock == 2);
    std.debug.assert(if (is_chroma) true else source_log2_blocks_per_macroblock == target_log2_block_per_macroblock);

    const max_value = (@as(u16, 1) << @as(u4, @intCast(task.frame.bit_depth))) - 1;
    const dc_offset = task.decoder.dc_offset;

    // Doubled for interlaced fields so consecutive field rows land two rows apart in the shared buffer
    const frame_coded_width = task.frame.coded_width << row_stride_shift;

    const ElementType = if (bytes_per_sample == 1) u8 else u16;
    const cast_frame_data = std.mem.bytesAsSlice(ElementType, frame_data);

    if (source_log2_blocks_per_macroblock == 2) {
        const coded_width = frame_coded_width;

        var j: u32 = 0;
        while (j < num_blocks) : (j += 4) {
            const result_1 = idct_8x8(
                slice_data[(j << 6)..][0..64].*,
                scaling_matrix_vec,
                dc_offset,
                max_value,
                ElementType,
            );
            const result_2 = idct_8x8(
                slice_data[(j << 6) + 64 ..][0..64].*,
                scaling_matrix_vec,
                dc_offset,
                max_value,
                ElementType,
            );
            const result_3 = idct_8x8(
                slice_data[(j << 6) + 128 ..][0..64].*,
                scaling_matrix_vec,
                dc_offset,
                max_value,
                ElementType,
            );
            const result_4 = idct_8x8(
                slice_data[(j << 6) + 192 ..][0..64].*,
                scaling_matrix_vec,
                dc_offset,
                max_value,
                ElementType,
            );

            switch (target_log2_block_per_macroblock) {
                0 => {
                    // 444->420, drop every even column and even row
                    const chroma_width = frame_coded_width >> 1;
                    const block_x = (slice_pos.x >> 1) + ((j >> 2) << 3);
                    const block_y = slice_pos.y >> 1;

                    // Top half
                    storeBlockOddColumns(
                        ElementType,
                        cast_frame_data,
                        chroma_width,
                        result_1,
                        result_3,
                        block_x,
                        block_y,
                        true,
                    );
                    // Bottom half
                    storeBlockOddColumns(
                        ElementType,
                        cast_frame_data,
                        chroma_width,
                        result_2,
                        result_4,
                        block_x,
                        block_y + 4,
                        true,
                    );
                },
                1 => {
                    // 444->422, drop every even column
                    const chroma_width = frame_coded_width >> 1;
                    const block_x = (slice_pos.x >> 1) + ((j >> 2) << 3);
                    const block_y = slice_pos.y;

                    // Top
                    storeBlockOddColumns(
                        ElementType,
                        cast_frame_data,
                        chroma_width,
                        result_1,
                        result_3,
                        block_x,
                        block_y,
                        false,
                    );
                    // Bottom
                    storeBlockOddColumns(
                        ElementType,
                        cast_frame_data,
                        chroma_width,
                        result_2,
                        result_4,
                        block_x,
                        block_y + 8,
                        false,
                    );
                },
                2 => {
                    // 444->444, keep as-is
                    const block_x = slice_pos.x + ((j >> 2) << 4);
                    const block_y = slice_pos.y;

                    // Order is different here than for luma!!
                    // Top-left
                    storeBlock(
                        ElementType,
                        cast_frame_data,
                        coded_width,
                        result_1,
                        block_x,
                        block_y,
                    );
                    // Top-right or bottom-left
                    storeBlock(
                        ElementType,
                        cast_frame_data,
                        coded_width,
                        result_2,
                        if (is_chroma) block_x else block_x + 8,
                        if (is_chroma) block_y + 8 else block_y,
                    );
                    // Bottom-left or top-right
                    storeBlock(
                        ElementType,
                        cast_frame_data,
                        coded_width,
                        result_3,
                        if (is_chroma) block_x + 8 else block_x,
                        if (is_chroma) block_y else block_y + 8,
                    );
                    // Bottom-right
                    storeBlock(
                        ElementType,
                        cast_frame_data,
                        coded_width,
                        result_4,
                        block_x + 8,
                        block_y + 8,
                    );
                },

                else => unreachable,
            }
        }
    } else {
        var j: u32 = 0;
        while (j < num_blocks) : (j += 2) {
            const result_t = idct_8x8(
                slice_data[(j << 6)..][0..64].*,
                scaling_matrix_vec,
                dc_offset,
                max_value,
                ElementType,
            );
            const result_b = idct_8x8(
                slice_data[(j << 6) + 64 ..][0..64].*,
                scaling_matrix_vec,
                dc_offset,
                max_value,
                ElementType,
            );

            switch (target_log2_block_per_macroblock) {
                0 => {
                    // 422->420, drop every even row
                    const coded_width = frame_coded_width >> 1;
                    const block_x = (slice_pos.x >> 1) + ((j >> 1) << 3);
                    const block_y = slice_pos.y >> 1;

                    // Top half
                    storeBlockOddRows(
                        ElementType,
                        cast_frame_data,
                        coded_width,
                        result_t,
                        block_x,
                        block_y,
                    );
                    // Bottom half
                    storeBlockOddRows(
                        ElementType,
                        cast_frame_data,
                        coded_width,
                        result_b,
                        block_x,
                        block_y + 4,
                    );
                },
                1 => {
                    // 422->422, keep as-is
                    const coded_width = frame_coded_width >> 1;
                    const block_x = (slice_pos.x >> 1) + ((j >> 1) << 3);
                    const block_y = slice_pos.y;

                    // Top
                    storeBlock(
                        ElementType,
                        cast_frame_data,
                        coded_width,
                        result_t,
                        block_x,
                        block_y,
                    );
                    // Bottom
                    storeBlock(
                        ElementType,
                        cast_frame_data,
                        coded_width,
                        result_b,
                        block_x,
                        block_y + 8,
                    );
                },
                2 => {
                    // 422->444, upsample by duplicating columns
                    const coded_width = frame_coded_width;
                    const block_x = slice_pos.x + ((j >> 1) << 4);
                    const block_y = slice_pos.y;

                    // Top
                    storeUpsampledBlock(
                        ElementType,
                        cast_frame_data,
                        coded_width,
                        result_t,
                        block_x,
                        block_y,
                    );
                    // Bottom
                    storeUpsampledBlock(
                        ElementType,
                        cast_frame_data,
                        coded_width,
                        result_b,
                        block_x,
                        block_y + 8,
                    );
                },
                else => unreachable,
            }
        }
    }
}

inline fn storeBlock(
    ElementType: type,
    frame_data: []ElementType,
    coded_width: u32,
    result: IdctReturnValue(ElementType),
    x: u32,
    y: u32,
) void {
    if (ElementType == u8) {
        inline for (0..4) |i| {
            const longs: @Vector(2, u64) = @bitCast(result[i]);
            frame_data[coded_width * (y + (i << 1) + 0) + x ..][0..8].* = @bitCast(longs[0]);
            frame_data[coded_width * (y + (i << 1) + 1) + x ..][0..8].* = @bitCast(longs[1]);
        }
    } else {
        inline for (0..8) |row| {
            frame_data[coded_width * (y + row) + x ..][0..8].* = result[row];
        }
    }
}

/// Columns are duplicated
inline fn storeUpsampledBlock(
    ElementType: type,
    frame_data: []ElementType,
    coded_width: u32,
    result: IdctReturnValue(ElementType),
    x: u32,
    y: u32,
) void {
    // In here, we rearrange the bytes such that each column is duplicated

    if (ElementType == u8) {
        inline for (0..4) |i| {
            const source = result[i];

            const row_a = misc.wasmShuffle(source, undefined, .{
                0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7,
            });
            const row_b = misc.wasmShuffle(source, undefined, .{
                8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15,
            });

            frame_data[coded_width * (y + (i << 1)) + x ..][0..16].* = row_a;
            frame_data[coded_width * (y + (i << 1) + 1) + x ..][0..16].* = row_b;
        }
    } else {
        inline for (0..8) |row| {
            const source: @Vector(16, u8) = @bitCast(result[row]);

            // Each value is two bytes long
            const row_l = misc.wasmShuffle(source, undefined, .{
                0, 1, 0, 1, 2, 3, 2, 3, 4, 5, 4, 5, 6, 7, 6, 7, // six seven
            });
            const row_r = misc.wasmShuffle(source, undefined, .{
                8, 9, 8, 9, 10, 11, 10, 11, 12, 13, 12, 13, 14, 15, 14, 15,
            });

            frame_data[coded_width * (y + row) + x ..][0..8].* = @bitCast(row_l);
            frame_data[coded_width * (y + row) + x + 8 ..][0..8].* = @bitCast(row_r);
        }
    }
}

/// By "odd" we mean the first, third, fifth, etc.
inline fn storeBlockOddRows(
    ElementType: type,
    frame_data: []ElementType,
    coded_width: u32,
    result: IdctReturnValue(ElementType),
    x: u32,
    y: u32,
) void {
    if (ElementType == u8) {
        inline for (0..4) |i| {
            const source: @Vector(2, u64) = @bitCast(result[i]);
            frame_data[coded_width * (y + i) + x ..][0..8].* = @bitCast(source[0]);
        }
    } else {
        inline for (0..4) |i| {
            const source = result[i << 1];
            frame_data[coded_width * (y + i) + x ..][0..8].* = source;
        }
    }
}

/// By "odd" we mean the first, third, fifth, etc.
inline fn storeBlockOddColumns(
    ElementType: type,
    frame_data: []ElementType,
    coded_width: u32,
    left: IdctReturnValue(ElementType),
    right: IdctReturnValue(ElementType),
    x: u32,
    y: u32,
    comptime drop_even_rows: bool,
) void {
    if (ElementType == u8) {
        inline for (0..4) |i| {
            const shuffled = misc.wasmShuffle(left[i], right[i], .{
                0, 2,  4,  6,  16, 18, 20, 22,
                8, 10, 12, 14, 24, 26, 28, 30,
            });
            const longs: @Vector(2, u64) = @bitCast(shuffled);

            if (drop_even_rows) {
                frame_data[coded_width * (y + i) + x ..][0..8].* = @bitCast(longs[0]);
            } else {
                frame_data[coded_width * (y + (i << 1) + 0) + x ..][0..8].* = @bitCast(longs[0]);
                frame_data[coded_width * (y + (i << 1) + 1) + x ..][0..8].* = @bitCast(longs[1]);
            }
        }
    } else {
        const rows = if (drop_even_rows)
            [_]u32{ 0, 2, 4, 6 }
        else
            [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 };

        inline for (rows, 0..) |row, i| {
            const a: @Vector(16, u8) = @bitCast(left[row]);
            const b: @Vector(16, u8) = @bitCast(right[row]);

            const shuffled = misc.wasmShuffle(a, b, .{
                0,  1,  4,  5,  8,  9,  12, 13,
                16, 17, 20, 21, 24, 25, 28, 29,
            });

            frame_data[coded_width * (y + i) + x ..][0..8].* = @bitCast(shuffled);
        }
    }
}

fn IdctReturnValue(ElementType: type) type {
    return if (ElementType == u8) [4]@Vector(16, u8) else [8]@Vector(8, u16);
}

inline fn idct_8x8(
    block: [64]f32,
    scaling_matrix: @Vector(64, f32),
    dc_offset: f32,
    max_value: u16,
    ElementType: type,
) IdctReturnValue(ElementType) {
    comptime std.debug.assert(ElementType == u8 or ElementType == u16);

    const Vec = @Vector(64, f32);
    var float_vec: Vec = block;
    float_vec *= scaling_matrix;
    float_vec[0] += dc_offset; // Add the DC dequant offset (already pre-scaled)

    var rows: [8]V8 = @bitCast(float_vec);
    rows = idct_columns(rows);
    rows = transpose_rows(rows);
    rows = idct_columns(rows);

    // WASM doesn't have a neat f32->u16 instruction, so we first do f32->u32, followed by u32->u16!
    // f32->u32 already clamps the bottom at 0, so we only need to clamp the top.

    if (ElementType == u8) {
        const row_pairs: [4]@Vector(16, f32) = @bitCast(rows);
        var result: [4]@Vector(16, u8) = undefined;

        // Iterate row pairs because 16 elements -> i8x16 vector type in WASM!
        inline for (0..4) |r| {
            @setRuntimeSafety(false); // Since the f32->u32 clamp is actually intended here

            var as_u32: @Vector(16, u32) = @intFromFloat(row_pairs[r]);
            as_u32 = @min(as_u32, @as(@Vector(16, u32), @splat(max_value)));

            const as_u16: @Vector(16, u16) = @intCast(as_u32);
            const as_u16_arr: [16]u16 = as_u16;
            const low_u16: @Vector(16, u8) = @bitCast(as_u16_arr[0..8].*);
            const high_u16: @Vector(16, u8) = @bitCast(as_u16_arr[8..16].*);

            const shuffled = @shuffle(u8, low_u16, high_u16, [_]i32{
                0,  2,  4,  6,  8,  10,  12,  14,
                -1, -3, -5, -7, -9, -11, -13, -15,
            });

            result[r] = shuffled;
        }

        return result;
    } else {
        // Iterate rows because 8 elements -> i16x8 vector type in WASM!
        var result: [8]@Vector(8, u16) = undefined;

        inline for (0..8) |r| {
            @setRuntimeSafety(false); // Since the f32->u32 clamp is actually intended here

            var as_u32: @Vector(8, u32) = @intFromFloat(rows[r]);
            as_u32 = @min(as_u32, @as(@Vector(8, u32), @splat(max_value)));

            result[r] = @as(@Vector(8, u16), @intCast(as_u32));
        }

        return result;
    }
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
