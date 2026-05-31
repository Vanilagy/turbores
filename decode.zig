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
const dc_unique_params = [_]u8{ 0x04, 0x28, 0x4D, 0x70 };
const dc_param_index = [_]u8{ 0, 1, 1, 2, 2, 3, 3 };
const run_to_cb = [_]u8{ 0x06, 0x06, 0x05, 0x05, 0x04, 0x29, 0x29, 0x29, 0x29, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x4C };
const lev_to_cb = [_]u8{ 0x04, 0x0A, 0x05, 0x06, 0x04, 0x28, 0x28, 0x28, 0x28, 0x4C };

// Same unique-codebook trick as DC, but for run and level separately.
const ac_run_unique_params = [_]u8{ 0x06, 0x05, 0x04, 0x29, 0x28, 0x4C };
const ac_run_index = [_]u8{ 0, 0, 1, 1, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 5 }; // run_to_cb collapsed to unique indices
const ac_lev_unique_params = [_]u8{ 0x04, 0x0A, 0x05, 0x06, 0x28, 0x4C };
const ac_lev_index = [_]u8{ 0, 1, 2, 3, 0, 4, 4, 4, 4, 5 }; // lev_to_cb collapsed to unique indices

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

const CachedDcParse = struct {
    values: [4]u16,
    num_values: u8,
    bits_read: u8,
};

const dc_cache_bits = 12;
var cached_dc_parses: [(1 << dc_cache_bits) * dc_unique_params.len]CachedDcParse = undefined;

var dc_cache_initted = true;

//fn initDcCache() void {
//    std.debug.assert(dc_cache_initted == false);
//
//    var data: [16]u8 = undefined;
//
//    for (dc_unique_params, 0..) |start_param, i| {
//        for (0..(1 << dc_cache_bits)) |j| {
//            data = @splat(0);
//            std.mem.writeInt(u32, data[0..4], j << (32 - dc_cache_bits), .big);
//            var code_reader = CodeReader.fromData(&data);
//
//            var entry = CachedDcParse{
//                .values = undefined,
//                .num_values = 0,
//                .bits_read = 0,
//            };
//
//            var param = start_param;
//
//            //printValues(.{ i, j });
//
//            while (true) {
//                const code = code_reader.getCode(param);
//
//                const bit_pos = code_reader.getBitPos();
//                if (bit_pos >= dc_cache_bits) {
//                    break;
//                }
//
//                entry.values[entry.num_values] = @intCast(code);
//                entry.num_values += 1;
//
//                param = dc_code_params[@min(@as(usize, @intCast(code)), 6)];
//                entry.bits_read = @intCast(bit_pos);
//
//                if (entry.num_values == 4) {
//                    break;
//                }
//            }
//
//            cached_dc_parses[(1 << dc_cache_bits) * i + j] = entry;
//        }
//    }
//}

const yoo = 2;
const CachedAcParse = struct {
    values: [2 * yoo]i16, // run, signed level alternating
    num_values: u8, // number of (run, level) pairs
    bits_read: u8,
};

const ac_cache_bits = 8;
const ac_pair_count = ac_run_unique_params.len * ac_lev_unique_params.len;
var cached_ac_parses: [(1 << ac_cache_bits) * ac_pair_count]CachedAcParse = undefined;

//fn initAcCache() void {
//    var data: [16]u8 = undefined;
//
//    for (ac_run_unique_params, 0..) |run_start, run_pi| {
//        for (ac_lev_unique_params, 0..) |lev_start, lev_pi| {
//            const pair = run_pi * ac_lev_unique_params.len + lev_pi;
//
//            for (0..(1 << ac_cache_bits)) |j| {
//                data = @splat(0);
//                std.mem.writeInt(u32, data[0..4], j << (32 - ac_cache_bits), .big);
//                var code_reader = CodeReader.fromData(&data);
//
//                var entry = CachedAcParse{
//                    .values = undefined,
//                    .num_values = 0,
//                    .bits_read = 0,
//                };
//
//                var run_param = run_start;
//                var lev_param = lev_start;
//
//                while (true) {
//                    // One (run, level, sign) tuple, matching the reference AC step.
//                    const run = code_reader.getCode(run_param);
//                    const level_code = code_reader.getCode(lev_param);
//                    const sign = -@as(i32, @intCast(code_reader.readBits(1)));
//                    code_reader.consume(1);
//
//                    const bit_pos = code_reader.getBitPos();
//                    if (bit_pos >= ac_cache_bits) {
//                        break; // tuple crosses the window, discard it whole
//                    }
//
//                    // Safe to interpret the values now: a kept tuple fits in the window, so the
//                    // codes are real (not decoded out of the trailing zero padding) and small.
//                    const level: i32 = @as(i32, @intCast(level_code)) + 1;
//
//                    entry.values[2 * entry.num_values] = @intCast(run);
//                    entry.values[2 * entry.num_values + 1] = @intCast((level ^ sign) - sign);
//                    entry.num_values += 1;
//                    entry.bits_read = @intCast(bit_pos);
//
//                    run_param = run_to_cb[@min(run, 15)];
//                    lev_param = lev_to_cb[@min(@as(u32, @intCast(level)), 9)];
//
//                    if (entry.num_values == yoo) {
//                        break;
//                    }
//                }
//
//                cached_ac_parses[(pair << ac_cache_bits) + j] = entry;
//            }
//        }
//    }
//}

fn printAcCacheStats() void {
    var zero_count: usize = 0;
    var sum_num_values: u64 = 0;
    var sum_bits_read: u64 = 0;
    var hist = [_]usize{0} ** 5; // num_values is 0..4

    for (&cached_ac_parses) |entry| {
        if (entry.num_values == 0) {
            zero_count += 1;
        }
        sum_num_values += entry.num_values;
        sum_bits_read += entry.bits_read;
        hist[entry.num_values] += 1;
    }

    const total = cached_ac_parses.len;

    var cumulative: usize = 0;
    var median: u8 = 0;
    for (0..hist.len) |v| {
        cumulative += hist[v];
        if (cumulative * 2 > total) {
            median = @intCast(v);
            break;
        }
    }

    const avg_num_values = @as(f64, @floatFromInt(sum_num_values)) / @as(f64, @floatFromInt(total));
    const avg_bits_read = @as(f64, @floatFromInt(sum_bits_read)) / @as(f64, @floatFromInt(total));

    print("ac cache: total={} num_values==0={} avg_num_values={d:.3} median_num_values={} avg_skip_bits={d:.3}\n", .{
        total, zero_count, avg_num_values, median, avg_bits_read,
    });
}

// Tiny per-code cache: one decoded code per 8-bit window, for run and level separately.
// bits_read == 0 is the sentinel for "didn't fit in 8 bits, decode it manually".
const RunLevelEntry = packed struct {
    bits_read: u3, // 1..7 when valid, 0 = sentinel
    value: u13,
};

var cached_run_codes: [256 * ac_run_unique_params.len]RunLevelEntry = undefined;
var cached_lev_codes: [256 * ac_lev_unique_params.len]RunLevelEntry = undefined;

//fn initSimpleCache(params: []const u8, cache: []RunLevelEntry) void {
//    var data: [16]u8 = undefined;
//
//    for (params, 0..) |param, pi| {
//        for (0..256) |j| {
//            data = @splat(0);
//            data[0] = @intCast(j); // the 8-bit window
//            var code_reader = CodeReader.fromData(&data);
//
//            const code = code_reader.getCode(param);
//            const bit_pos = code_reader.getBitPos();
//
//            cache[pi * 256 + j] = if (bit_pos >= 8)
//                .{ .bits_read = 0, .value = 0 } // code spills past the window, defer to manual
//            else
//                .{ .bits_read = @intCast(bit_pos), .value = @intCast(code) };
//        }
//    }
//}

// Byte-aligned codeword cache: (codebook, bit offset, byte) -> one codeword.
// bits == 0 is the sentinel ("codeword spills past this byte, decode manually").
const CwEntry = packed struct {
    bits: u4, // 1..8 when valid, 0 = sentinel
    value: u12,
};

var run_cw_table: [ac_run_unique_params.len * 8 * 256]CwEntry = undefined;
var lev_cw_table: [ac_lev_unique_params.len * 8 * 256]CwEntry = undefined;

fn initCwTable(params: []const u8, table: []CwEntry) void {
    for (params, 0..) |param, ci| {
        for (0..8) |o| {
            for (0..256) |byte| {
                // Place byte bits [o, 8) at the MSB of a u32, zero-padded after.
                const word: u32 = @as(u32, @intCast(byte)) << @intCast(24 + o);
                const parsed = parseCode(word, param);

                table[(ci * 8 + o) * 256 + byte] = if (parsed.bits <= 8 - o)
                    .{ .bits = @intCast(parsed.bits), .value = @intCast(parsed.value) }
                else
                    .{ .bits = 0, .value = 0 }; // spills past the byte
            }
        }
    }
}

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

    const first_code_result = parseCode2(bit_reader.current, 0xb8);
    var code: i32 = @intCast(first_code_result.value);

    const first_dc = (code >> 1) ^ -(code & 1);

    decoder.slice_data[0] = first_dc;

    var prev_dc = first_dc;
    //code = 5;
    //var sign: i32 = 0;

    const second_code_result = parseCode2(
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

        const code_result_1 = parseCode2(bit_reader.current, dc_code_params[@min(@as(usize, @intCast(code)), 6)]);

        code = @intCast(code_result_1.value);
        sign = @intFromBool(code > 0) * (sign ^ -(code & 1)); // else 0

        const result_1 = prev_dc + (((code + 1) >> 1) ^ sign) - sign;
        decoder.slice_data[64 * j] = result_1;

        const code_result_2 = parseCode2(
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

        const run_result = parseCode2(bit_reader.current, run_to_cb[@min(run, 15)]);

        run = run_result.value;
        pos += run + 1;

        const level_result = parseCode2(bit_reader.current << @as(u6, @intCast(run_result.bits)), lev_to_cb[@min(@as(u32, @intCast(level)), 9)]);
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

        //printValues(.{ slice_size, luma_data_size, u_data_size, v_data_size });

        @memset(decoder.slice_data, 0);

        const ac_data = reader.take(luma_data_size);
        var bit_reader = BitReader.fromData(ac_data);

        if (true) {
            parseDc(decoder, &bit_reader, num_luma_blocks);

            //bit_reader.maybeLoadData();
            //
            //const first_code_result = parseCode2(bit_reader.current, 0xb8);
            //var code: i32 = @intCast(first_code_result.value);
            //
            //const first_dc = (code >> 1) ^ -(code & 1);
            //
            //decoder.slice_data[0] = first_dc;
            //
            //var prev_dc = first_dc;
            ////code = 5;
            ////var sign: i32 = 0;
            //
            //const second_code_result = parseCode2(
            //    bit_reader.current << @as(u6, @intCast(first_code_result.bits)),
            //    0x70,
            //);
            //code = @intCast(second_code_result.value);
            //var sign: i32 = if (code > 0) -(code & 1) else 0;
            //
            //const result = prev_dc + (((code + 1) >> 1) ^ sign) - sign;
            //decoder.slice_data[64] = result;
            //prev_dc = result;
            //
            //bit_reader.consume(@intCast(first_code_result.bits + second_code_result.bits));
            //
            //var j: usize = 2;
            //while (j < num_luma_blocks) {
            //    bit_reader.maybeLoadData();
            //
            //    const code_result_1 = parseCode2(bit_reader.current, dc_code_params[@min(@as(usize, @intCast(code)), 6)]);
            //
            //    code = @intCast(code_result_1.value);
            //    sign = if (code > 0) sign ^ -(code & 1) else 0;
            //
            //    const result_1 = prev_dc + (((code + 1) >> 1) ^ sign) - sign;
            //    decoder.slice_data[64 * j] = result_1;
            //
            //    const code_result_2 = parseCode2(
            //        bit_reader.current << @as(u6, @intCast(code_result_1.bits)),
            //        dc_code_params[@min(code_result_1.value, 6)],
            //    );
            //
            //    code = @intCast(code_result_2.value);
            //    sign = if (code > 0) sign ^ -(code & 1) else 0;
            //
            //    const result_2 = result_1 + (((code + 1) >> 1) ^ sign) - sign;
            //
            //    decoder.slice_data[64 * j + 64] = result_2;
            //    prev_dc = result_2;
            //
            //    j += 2;
            //    bit_reader.consume(@intCast(code_result_1.bits + code_result_2.bits));
            //}
        }

        //if (false) {
        //    var code: i32 = @intCast(code_reader.getCode(0xB8));
        //
        //    decoder.slice_data[0] = (code >> 1) ^ -(code & 1);
        //
        //    code = 5;
        //    var sign: i32 = 0;
        //
        //    var j: usize = 1;
        //    while (j < num_luma_blocks) {
        //        const bits = code_reader.readBits(dc_cache_bits);
        //        const param_index: usize = dc_param_index[@min(@as(usize, @intCast(code)), 6)];
        //        const entry = &cached_dc_parses[(param_index << dc_cache_bits) + bits];
        //
        //        if (entry.num_values == 0) {
        //            const start = code_reader.getBitPos();
        //            code = @intCast(code_reader.getCode(dc_unique_params[param_index]));
        //            sign = @intFromBool(code > 0) * (sign ^ -(code & 1));
        //
        //            decoder.slice_data[64 * j] = decoder.slice_data[64 * j - 64] + (((code + 1) >> 1) ^ sign) - sign;
        //            j += 1;
        //
        //            _ = start;
        //
        //            //printValues(.{code_reader.getBitPos() - start});
        //
        //            dont += 1;
        //        } else {
        //            for (0..entry.num_values) |k| {
        //                if (j == num_luma_blocks) {
        //                    break;
        //                }
        //
        //                code = @intCast(entry.values[k]);
        //                sign = @intFromBool(code > 0) * (sign ^ -(code & 1));
        //
        //                decoder.slice_data[64 * j] = decoder.slice_data[64 * j - 64] + (((code + 1) >> 1) ^ sign) - sign;
        //                j += 1;
        //            }
        //
        //            fit_in_byte += entry.num_values;
        //
        //            code_reader.consume(entry.bits_read);
        //        }
        //    }
        //}

        //if (false) {
        //    var run: u32 = 4;
        //    var level: i32 = 2;
        //    //let sign = 0;
        //
        //    //const scanOrderInverse = Array.from({ length: 64 }).fill(0);
        //    //for (let i = 0; i < 64; i++) {
        //    //    scanOrderInverse[scanOrder[i]] = i;
        //    //}
        //
        //    const log2_block_count = std.math.log2_int(u32, num_luma_blocks); // Math.floor(Math.log2(numBlocks));
        //    const max_coeffs = @as(u32, 64) << log2_block_count;
        //    _ = max_coeffs;
        //
        //    const block_mask = num_luma_blocks - 1;
        //    var pos = block_mask;
        //
        //    while (true) {
        //        code_reader.maybeLoadData();
        //
        //        const bits_left = code_reader.getRemainingBits(); // gb->size_in_bits - re_index;
        //        if (bits_left < 32) {
        //            if (bits_left == 0) {
        //                break;
        //            }
        //
        //            if (code_reader.readBitsAssumingLoaded(@intCast(bits_left)) == 0) {
        //                break;
        //            }
        //        }
        //        //if (bits_left == 0 or (bits_left < 32 and code_reader.readBits(@intCast(bits_left)) == 0)) {
        //        //    break;
        //        //}
        //
        //        run = code_reader.getCode(run_to_cb[@min(run, 15)]); // getCode(run_to_cb[Math.min(run, 15)]);
        //        //const run_eye = code_reader.getBitPos();
        //        //const run_bits = code_reader.getBitPos() - run_eye;
        //        //ac_cw_bits_sum += run_bits;
        //        //ac_cw_count += 1;
        //        //ac_cw_hist[@min(run_bits, 31)] += 1;
        //        //DECODE_CODEWORD(run, run_to_cb[FFMIN(run,  15)], LAST_SKIP_BITS);
        //        pos += run + 1;
        //
        //        //if (pos >= max_coeffs) {
        //        //    std.debug.assert(false); // Proper error here
        //        //    //throw new Error('ac text damaged');
        //        //}
        //
        //        level = @intCast(code_reader.getCode(lev_to_cb[@min(@as(u32, @intCast(level)), 9)]));
        //        //const lev_eye = code_reader.getBitPos();
        //        //const lev_bits = code_reader.getBitPos() - lev_eye;
        //        //ac_cw_bits_sum += lev_bits;
        //        //ac_cw_count += 1;
        //        //ac_cw_hist[@min(lev_bits, 31)] += 1;
        //        //DECODE_CODEWORD(level, lev_to_cb[FFMIN(level, 9)], SKIP_BITS);
        //        level += 1;
        //
        //        const j = pos >> log2_block_count;
        //
        //        const sign = -@as(i32, @intCast(code_reader.readBitsAssumingLoaded(1)));
        //        code_reader.consume(1);
        //
        //        //_ = j;
        //        //_ = sign;
        //        //_ = scan_order;
        //
        //        //printValues(.{ run, level, sign });
        //
        //        //sign = SHOW_SBITS(re, gb, 1);
        //        //SKIP_BITS(re, gb, 1);
        //        decoder.slice_data[((pos & block_mask) << 6) + scan_order[j]] = (level ^ sign) - sign;
        //
        //        //out[((pos & block_mask) << 6) + ctx->scan[i]] = ((level ^ sign) - sign);
        //    }
        //}

        if (true) {
            parseAc(decoder, &bit_reader, num_luma_blocks);

            //var run: u32 = 4;
            //var level: i32 = 2;
            //
            //const log2_block_count = std.math.log2_int(u32, num_luma_blocks); // Math.floor(Math.log2(numBlocks));
            //const max_coeffs = @as(u32, 64) << log2_block_count;
            //_ = max_coeffs;
            //
            //const block_mask = num_luma_blocks - 1;
            //var pos = block_mask;
            //
            //while (true) {
            //    bit_reader.maybeLoadData();
            //
            //    if (bit_reader.current == 0) {
            //        break;
            //    }
            //
            //    const run_result = parseCode2(bit_reader.current, run_to_cb[@min(run, 15)]);
            //
            //    run = run_result.value;
            //    pos += run + 1;
            //
            //    const level_result = parseCode2(bit_reader.current << @as(u6, @intCast(run_result.bits)), lev_to_cb[@min(@as(u32, @intCast(level)), 9)]);
            //    level = @intCast(level_result.value);
            //    level += 1;
            //
            //    const j = pos >> log2_block_count;
            //    const thing = run_result.bits + level_result.bits + 1;
            //
            //    const sign = -@as(i32, @intCast((bit_reader.current >> @as(u6, @intCast(64 - thing))) & 1));
            //
            //    bit_reader.consume(@intCast(thing));
            //
            //    decoder.slice_data[((pos & block_mask) << 6) + scan_order[j]] = (level ^ sign) - sign;
            //}
        }

        // Byte-aligned codeword tables, no CodeReader. Track a bit position into ac_data;
        // each run/level is one table lookup (sentinel -> manual parse), sign read by hand.
        //if (false) {
        //    var run: u32 = 4;
        //    var level: i32 = 2;
        //
        //    const log2_block_count = std.math.log2_int(u32, num_luma_blocks);
        //    const block_mask = num_luma_blocks - 1;
        //    var pos = block_mask;
        //
        //    const total_bits = ac_data.len * 8;
        //    var bp = code_reader.getBitPos();
        //
        //    while (true) {
        //        if (bp >= total_bits) {
        //            break;
        //        }
        //        const bits_left = total_bits - bp;
        //        if (bits_left < 32 and (buildWord(ac_data, bp) >> @as(u5, @intCast(32 - bits_left))) == 0) {
        //            break;
        //        }
        //
        //        // run
        //        {
        //            const cb = ac_run_index[@min(run, 15)];
        //            const o = bp & 7;
        //            const entry = run_cw_table[(@as(usize, cb) * 8 + o) * 256 + @as(usize, ac_data[bp >> 3])];
        //            if (entry.bits != 0) {
        //                run_cw_hits += 1;
        //                run = entry.value;
        //                bp += entry.bits;
        //            } else {
        //                run_cw_misses += 1;
        //                const parsed = parseCode(buildWord(ac_data, bp), ac_run_unique_params[cb]);
        //                run = parsed.value;
        //                bp += parsed.bits;
        //            }
        //        }
        //        pos += run + 1;
        //
        //        // level
        //        {
        //            const cb = ac_lev_index[@min(@as(u32, @intCast(level)), 9)];
        //            const o = bp & 7;
        //            const entry = lev_cw_table[(@as(usize, cb) * 8 + o) * 256 + @as(usize, ac_data[bp >> 3])];
        //            if (entry.bits != 0) {
        //                lev_cw_hits += 1;
        //                level = @as(i32, entry.value) + 1;
        //                bp += entry.bits;
        //            } else {
        //                lev_cw_misses += 1;
        //                const parsed = parseCode(buildWord(ac_data, bp), ac_lev_unique_params[cb]);
        //                level = @as(i32, @intCast(parsed.value)) + 1;
        //                bp += parsed.bits;
        //            }
        //        }
        //
        //        // sign (1 bit, MSB-first within the byte)
        //        const sign = -@as(i32, (ac_data[bp >> 3] >> @as(u3, @intCast(7 - (bp & 7)))) & 1);
        //        bp += 1;
        //
        //        const j = pos >> log2_block_count;
        //        decoder.slice_data[((pos & block_mask) << 6) + scan_order[j]] = (level ^ sign) - sign;
        //    }
        //}
        //
        //if (false) {
        //    var run: u32 = 4;
        //    var level: i32 = 2;
        //
        //    const log2_block_count = std.math.log2_int(u32, num_luma_blocks);
        //    const block_mask = num_luma_blocks - 1;
        //    var pos = block_mask;
        //
        //    while (true) {
        //        const bits_left = code_reader.getRemainingBits();
        //        if (bits_left <= 0 or (bits_left < 32 and code_reader.readBits(@intCast(bits_left)) == 0)) {
        //            break;
        //        }
        //
        //        // Only take the cache path with comfortable headroom. With >= 32 bits left
        //        // the whole window is real stream data (trailing zero padding is < 8 bits and
        //        // only ever shows up once bits_left drops below 32), so the cached tuples are
        //        // exactly the ones the reference loop would decode. The tail goes slow-path,
        //        // which keeps the original all-zero termination behaviour intact.
        //        if (bits_left >= 32) {
        //            const run_pi = ac_run_index[@min(run, 15)];
        //            const lev_pi = ac_lev_index[@min(@as(u32, @intCast(level)), 9)];
        //            const pair = @as(usize, run_pi) * ac_lev_unique_params.len + lev_pi;
        //            const window: usize = code_reader.readBits(ac_cache_bits);
        //            const entry = &cached_ac_parses[(pair << ac_cache_bits) + window];
        //
        //            if (entry.num_values != 0) {
        //                for (0..entry.num_values) |k| {
        //                    run = @intCast(entry.values[2 * k]);
        //                    pos += run + 1;
        //                    const j = pos >> log2_block_count;
        //                    level = entry.values[2 * k + 1];
        //                    decoder.slice_data[((pos & block_mask) << 6) + scan_order[j]] = level;
        //                }
        //
        //                // level held the signed coefficient; the next codebook wants its magnitude.
        //                level = @intCast(@abs(level));
        //
        //                fit_in_byte += 1;
        //                mh2 += @floatFromInt(entry.num_values);
        //                mh3 += @floatFromInt(entry.bits_read);
        //
        //                code_reader.consume(entry.bits_read);
        //                continue;
        //            }
        //
        //            dont += 1;
        //        }
        //
        //        run = code_reader.getCode(run_to_cb[@min(run, 15)]);
        //        pos += run + 1;
        //        level = @intCast(code_reader.getCode(lev_to_cb[@min(@as(u32, @intCast(level)), 9)]));
        //        level += 1;
        //
        //        const j = pos >> log2_block_count;
        //        const sign = -@as(i32, @intCast(code_reader.readBits(1)));
        //        code_reader.consume(1);
        //        decoder.slice_data[((pos & block_mask) << 6) + scan_order[j]] = (level ^ sign) - sign;
        //    }
        //}
        //
        //// Tiny per-code cache: one run lookup, one level lookup, sign parsed manually. No
        //// gate needed - each lookup is a faithful 1:1 replacement of a getCode (it never
        //// greedily decodes past the window), so it matches the reference everywhere, tail
        //// included (readBits zero-pads safely past the end of the buffer).
        //if (false) {
        //    var run: u32 = 4;
        //    var level: i32 = 2;
        //
        //    const log2_block_count = std.math.log2_int(u32, num_luma_blocks);
        //    const block_mask = num_luma_blocks - 1;
        //    var pos = block_mask;
        //
        //    while (true) {
        //        const bits_left = code_reader.getRemainingBits();
        //        if (bits_left <= 0 or (bits_left < 32 and code_reader.readBits(@intCast(bits_left)) == 0)) {
        //            break;
        //        }
        //
        //        const run_pi = ac_run_index[@min(run, 15)];
        //        const run_w: usize = code_reader.readBits(8);
        //        const run_entry = cached_run_codes[@as(usize, run_pi) * 256 + run_w];
        //        if (run_entry.bits_read != 0) {
        //            run = run_entry.value;
        //            code_reader.consume(run_entry.bits_read);
        //            fit_in_byte += 1;
        //        } else {
        //            run = code_reader.getCode(ac_run_unique_params[run_pi]);
        //            dont += 1;
        //        }
        //        pos += run + 1;
        //
        //        const lev_pi = ac_lev_index[@min(@as(u32, @intCast(level)), 9)];
        //        const lev_w: usize = code_reader.readBits(8);
        //        const lev_entry = cached_lev_codes[@as(usize, lev_pi) * 256 + lev_w];
        //        if (lev_entry.bits_read != 0) {
        //            level = @as(i32, lev_entry.value) + 1;
        //            code_reader.consume(lev_entry.bits_read);
        //            fit_in_byte += 1;
        //        } else {
        //            level = @as(i32, @intCast(code_reader.getCode(ac_lev_unique_params[lev_pi]))) + 1;
        //            dont += 1;
        //        }
        //
        //        const j = pos >> log2_block_count;
        //        const sign = -@as(i32, @intCast(code_reader.readBits(1)));
        //        code_reader.consume(1);
        //        decoder.slice_data[((pos & block_mask) << 6) + scan_order[j]] = (level ^ sign) - sign;
        //    }
        //}

        if (i == 6) {
            //std.debug.assert(false);
        }

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

                    //const mh: [64]f32 = undefined @floatFromInt(block.*);

                    //decoder.frame_data[decoder.coded_width * (block_y + (k / 8)) + block_x + (k % 8)] = @floatFromInt(value);
                }

                idct8x8(&mh);

                for (0..8) |x| {
                    for (0..8) |y| {
                        decoder.frame_data[decoder.coded_width * (block_y + y) + block_x + x] = mh[y * 8 + x] / 1024;
                    }
                }
            }
        }

        //for (0..num_luma_blocks) |j| {
        //    const block_offset_x = 16 * (j / 4) + 8 * (j % 2);
        //    const block_offset_y: u32 = if (j % 4 < 2) 0 else 8;
        //    const block_x = slice_x + block_offset_x;
        //    const block_y = slice_y + block_offset_y;
        //
        //    const unquantized = 4096 + ((decoder.slice_data[64 * j] * q_mat_luma[0] * scale_factor) >> 2);
        //    const normalized = @as(f32, @floatFromInt(unquantized)) / (2 * 4096);
        //
        //    for (0..8) |x| {
        //        for (0..8) |y| {
        //            decoder.frame_data[decoder.coded_width * (block_y + y) + block_x + x] = normalized;
        //        }
        //    }
        //}

        reader.pos = slice_start_pos + slice_size;

        slice_x += 16 * slice_width;

        if (slice_x >= decoder.coded_width) {
            slice_x = 0;
            slice_y += 16 * slice_height;
        }
    }

    printValues(.{ fit_in_byte, dont, mh2 / @as(f64, @floatFromInt(fit_in_byte)), mh3 / @as(f64, @floatFromInt(fit_in_byte)), mh4 / le_count });

    if (false) {
        print("ac codeword bits: avg={d:.4} n={} hist={any}\n", .{
            @as(f64, @floatFromInt(ac_cw_bits_sum)) / @as(f64, @floatFromInt(ac_cw_count)),
            ac_cw_count,
            ac_cw_hist,
        });

        print("cw table run: hits={} misses={} hit_rate={d:.4}\n", .{
            run_cw_hits,
            run_cw_misses,
            @as(f64, @floatFromInt(run_cw_hits)) / @as(f64, @floatFromInt(run_cw_hits + run_cw_misses)),
        });
        print("cw table lev: hits={} misses={} hit_rate={d:.4}\n", .{
            lev_cw_hits,
            lev_cw_misses,
            @as(f64, @floatFromInt(lev_cw_hits)) / @as(f64, @floatFromInt(lev_cw_hits + lev_cw_misses)),
        });
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

var fit_in_byte: u32 = 0;
var mh2: f64 = 0;
var mh3: f64 = 0;
var mh4: f64 = 0;
var le_count: f64 = 0;
var dont: u32 = 0;

// AC codeword size intel (run + level codewords, excluding the sign bit).
var ac_cw_bits_sum: u64 = 0;
var ac_cw_count: u64 = 0;
var ac_cw_hist: [32]u64 = [_]u64{0} ** 32;

// Byte-aligned codeword table: cache hits vs manual parseCode fallbacks.
var run_cw_hits: u64 = 0;
var run_cw_misses: u64 = 0;
var lev_cw_hits: u64 = 0;
var lev_cw_misses: u64 = 0;

const ParsedCode = struct { value: u32, bits: u32 };

// Parse one exp-Golomb/Rice codeword from a u32 with the codeword left-aligned at the MSB.
inline fn parseCode(word: u32, params: u8) ParsedCode {
    const mp = params & 0b11;
    const g: u3 = @intCast((params >> 2) & 0b111);
    const r: u3 = @intCast(params >> 5);

    const n = @clz(word);
    const big: u32 = 0 -% @as(u32, @intFromBool(n > mp));
    const base = std.math.shl(u32, @min(n, mp + 1), r);
    const sub = @as(u32, 1) << @as(u5, @intCast(r ^ (big & (g ^ r))));
    const bits = @min((n + 1 + r) +% (big & (n +% g -% mp -% 1 -% r)), 32);
    const raw: u32 = word >> @as(u5, @intCast(32 - bits));

    return .{ .value = base +% raw -% sub, .bits = @intCast(bits) };
}

inline fn parseCode2(word: u64, params: u8) ParsedCode {
    const mp: u32 = params & 0b11;
    const g: u32 = (params >> 2) & 0b111;
    const r: u32 = params >> 5;

    const n: u32 = @clz(word);
    const is_big = n > mp;

    const base = std.math.shl(u32, @min(n, mp + 1), r);
    //const base = @min(n, mp + 1) << @as(u5, @intCast(r));

    // Pre-compute both arms (wrapping so the unused arm can't trap), then let the
    // compiler emit a wasm `select` instead of branchy masking.
    const bits_big = 2 *% n +% g -% mp;
    const bits_small = n + 1 + r;
    const bits = if (is_big) bits_big else bits_small;
    const sub = @as(u32, 1) << (if (is_big) @intCast(g) else @intCast(r));

    const raw: u32 = @intCast(word >> @as(u6, @intCast(64 - bits)));

    //const raw = self.readBitsAssumingLoaded(@intCast(bits));
    //self.consume(@intCast(bits));

    const result = base +% raw -% sub;

    return .{
        .value = result,
        .bits = bits,
    };
}

// Build a u32 with the bits starting at position `bp` left-aligned at the MSB. Reads a single
// u32 and shifts by the sub-byte offset, so only the top 25 bits are valid - plenty for our codes.
inline fn buildWord(data: []const u8, bp: usize) u32 {
    const bi = bp >> 3;
    const o: u5 = @intCast(bp & 7);

    if (bi + 4 > data.len) {
        // Within the last few bytes of the buffer: assemble what's left, zero-padded.
        var w: u32 = 0;
        for (bi..data.len, 0..) |k, idx| {
            w |= @as(u32, data[k]) << @intCast(24 - idx * 8);
        }
        return w << o;
    }

    return std.mem.readInt(u32, data[bi..][0..4], .big) << o;
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

    //inline fn getCode(self: *CodeReader, params: u8) u32 {
    //    const mp: u32 = params & 0b11;
    //    const g: u32 = (params >> 2) & 0b111;
    //    const r: u32 = params >> 5;
    //
    //    const n: u32 = @clz(self.current);
    //    const is_big = n > mp;
    //
    //    const base = std.math.shl(u32, @min(n, mp + 1), r);
    //
    //    const bits_big = 2 *% n +% g -% mp;
    //    const bits_small = n + 1 + r;
    //    const bits = if (is_big) bits_big else bits_small;
    //    const sub = @as(u32, 1) << (if (is_big) @intCast(g) else @intCast(r));
    //
    //    const raw = self.readBitsAssumingLoaded(@intCast(bits));
    //    self.consume(@intCast(bits));
    //
    //    return base +% raw -% sub;
    //}

    //inline fn readBitsAssumingLoaded(self: *CodeReader, bits: u8) u32 {
    //    //printValues(.{ "ay", bits });
    //    return @intCast(self.current >> @as(u6, @intCast(64 - bits)));
    //}
    //
    //inline fn readBits(self: *CodeReader, bits: u8) u32 {
    //    self.maybeLoadData();
    //    return self.readBitsAssumingLoaded(bits);
    //}

    inline fn consume(self: *BitReader, bits: u8) void {
        self.current <<= @as(u6, @intCast(bits));
        self.current |= self.next >> @as(u6, @intCast(64 - bits));
        self.next <<= @as(u6, @intCast(bits));
        self.bit_health -= bits;
    }

    //inline fn getRemainingBits(self: *CodeReader) u32 {
    //    return (self.reader.remaining() << 3) + self.bit_health;
    //}
    //
    //inline fn getBitPos(self: *CodeReader) usize {
    //    return self.reader.pos * 8 - self.bit_health;
    //}
};
