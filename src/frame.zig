const misc = @import("./misc.zig");
const gpa = misc.gpa;

pub const Frame = struct {
    frame_data: []align(16) u8,
    coded_width: u32,
    coded_height: u32,
    visible_width: u32,
    visible_height: u32,
    log2_chroma_blocks_per_mb: u32,
    /// 0 => no alpha \
    /// 8, 16 => source alpha bit depth \
    /// -1 => no alpha present in source, but must emit alpha channel anyway
    alpha_bit_depth: i32,
    bit_depth: u32,
    color_primaries: u32,
    color_transfer: u32,
    color_matrix: u32,
};

export fn createFrame() ?*Frame {
    const result = gpa.create(Frame) catch return null;

    result.* = .{
        .frame_data = &.{},
        .coded_width = undefined,
        .coded_height = undefined,
        .visible_width = undefined,
        .visible_height = undefined,
        .log2_chroma_blocks_per_mb = undefined,
        .alpha_bit_depth = undefined,
        .bit_depth = undefined,
        .color_primaries = undefined,
        .color_transfer = undefined,
        .color_matrix = undefined,
    };

    return result;
}

export fn closeFrame(frame: *Frame) void {
    gpa.free(frame.frame_data);
    gpa.destroy(frame);
}

export fn getVisibleWidth(frame: *Frame) u32 {
    return frame.visible_width;
}

export fn getVisibleHeight(frame: *Frame) u32 {
    return frame.visible_height;
}

export fn getCodedWidth(frame: *Frame) u32 {
    return frame.coded_width;
}

export fn getCodedHeight(frame: *Frame) u32 {
    return frame.coded_height;
}

export fn getFrameDataPtr(frame: *Frame) [*]u8 {
    return frame.frame_data.ptr;
}

export fn getFrameDataSize(frame: *Frame) usize {
    return frame.frame_data.len;
}

export fn getFramePixelFormat(frame: *Frame) u32 {
    return @intFromEnum(getYuvPixelFormat(
        frame.log2_chroma_blocks_per_mb,
        frame.bit_depth,
        frame.alpha_bit_depth != 0,
    ));
}

export fn getColorPrimaries(frame: *Frame) u32 {
    return frame.color_primaries;
}

export fn getColorTransfer(frame: *Frame) u32 {
    return frame.color_transfer;
}

export fn getColorMatrix(frame: *Frame) u32 {
    return frame.color_matrix;
}

pub const PixelFormat = enum(u5) {
    // 4:2:0 Y, U, V
    i420,
    i420p10,
    i420p12,
    // 4:2:0 Y, U, V, A
    i420a,
    i420ap10,
    i420ap12,
    // 4:2:2 Y, U, V
    i422,
    i422p10,
    i422p12,
    // 4:2:2 Y, U, V, A
    i422a,
    i422ap10,
    i422ap12,
    // 4:4:4 Y, U, V
    i444,
    i444p10,
    i444p12,
    // 4:4:4 Y, U, V, A
    i444a,
    i444ap10,
    i444ap12,
};

pub fn getYuvPixelFormat(log2_chroma_blocks_per_mb: u32, bit_depth: u32, has_alpha: bool) PixelFormat {
    return switch (log2_chroma_blocks_per_mb) {
        0 => switch (bit_depth) {
            8 => if (has_alpha) .i420a else .i420,
            10 => if (has_alpha) .i420ap10 else .i420p10,
            12 => if (has_alpha) .i420ap12 else .i420p12,
            else => unreachable,
        },
        1 => switch (bit_depth) {
            8 => if (has_alpha) .i422a else .i422,
            10 => if (has_alpha) .i422ap10 else .i422p10,
            12 => if (has_alpha) .i422ap12 else .i422p12,
            else => unreachable,
        },
        2 => switch (bit_depth) {
            8 => if (has_alpha) .i444a else .i444,
            10 => if (has_alpha) .i444ap10 else .i444p10,
            12 => if (has_alpha) .i444ap12 else .i444p12,
            else => unreachable,
        },
        else => unreachable,
    };
}
