// Copyright (c) 2026-present, Vanilagy and contributors
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const misc = @import("./misc.zig");
const worker = @import("./worker.zig");
const decoder = @import("./decoder.zig");
const frame = @import("./frame.zig");

comptime {
    if (misc.is_wasm) {
        @export(&misc.setIsBrowserMainThread, .{ .name = "setIsBrowserMainThread" });

        @export(&worker.allocateWorkerStack, .{ .name = "allocateWorkerStack" });
        @export(&worker.allocateThreadLocalState, .{ .name = "allocateThreadLocalState" });
        @export(&worker.startWorker, .{ .name = "startWorker" });

        @export(&decoder.createDecoder, .{ .name = "createDecoder" });
        @export(&decoder.closeDecoder, .{ .name = "closeDecoder" });
        @export(&decoder.allocatePacket, .{ .name = "allocatePacket" });
        @export(&decoder.decodePacketWasm, .{ .name = "decodePacket" });
        @export(&decoder.getTaskStateAddress, .{ .name = "getTaskStateAddress" });
        @export(&decoder.finalizePacketDecoding, .{ .name = "finalizePacketDecoding" });
        @export(&decoder.getErrorMessagePtr, .{ .name = "getErrorMessagePtr" });
        @export(&decoder.getErrorMessageSize, .{ .name = "getErrorMessageSize" });

        @export(&frame.createFrame, .{ .name = "createFrame" });
        @export(&frame.closeFrame, .{ .name = "closeFrame" });
        @export(&frame.getVisibleWidth, .{ .name = "getVisibleWidth" });
        @export(&frame.getVisibleHeight, .{ .name = "getVisibleHeight" });
        @export(&frame.getCodedWidth, .{ .name = "getCodedWidth" });
        @export(&frame.getCodedHeight, .{ .name = "getCodedHeight" });
        @export(&frame.getFrameDataPtr, .{ .name = "getFrameDataPtr" });
        @export(&frame.getFrameDataSize, .{ .name = "getFrameDataSize" });
        @export(&frame.getFramePixelFormat, .{ .name = "getFramePixelFormat" });
        @export(&frame.getOriginalPixelFormat, .{ .name = "getOriginalPixelFormat" });
        @export(&frame.getAspectRatioNum, .{ .name = "getAspectRatioNum" });
        @export(&frame.getAspectRatioDen, .{ .name = "getAspectRatioDen" });
        @export(&frame.getColorPrimaries, .{ .name = "getColorPrimaries" });
        @export(&frame.getColorTransfer, .{ .name = "getColorTransfer" });
        @export(&frame.getColorMatrix, .{ .name = "getColorMatrix" });
        @export(&frame.getScanType, .{ .name = "getScanType" });
    } else {
        @export(&decoder.createDecoderNative, .{ .name = "turbores_decoder_create" });
        @export(&decoder.closeDecoder, .{ .name = "turbores_decoder_destroy" });
        @export(&decoder.decodePacketNative, .{ .name = "turbores_decode" });
        @export(&decoder.getErrorMessagePtr, .{ .name = "turbores_decoder_error_message_ptr" });
        @export(&decoder.getErrorMessageSize, .{ .name = "turbores_decoder_error_message_size" });

        @export(&frame.createFrame, .{ .name = "turbores_frame_create" });
        @export(&frame.closeFrame, .{ .name = "turbores_frame_destroy" });
        @export(&frame.getVisibleWidth, .{ .name = "turbores_frame_visible_width" });
        @export(&frame.getVisibleHeight, .{ .name = "turbores_frame_visible_height" });
        @export(&frame.getCodedWidth, .{ .name = "turbores_frame_coded_width" });
        @export(&frame.getCodedHeight, .{ .name = "turbores_frame_coded_height" });
        @export(&frame.getFrameDataPtr, .{ .name = "turbores_frame_data_ptr" });
        @export(&frame.getFrameDataSize, .{ .name = "turbores_frame_data_size" });
        @export(&frame.getFramePixelFormat, .{ .name = "turbores_frame_pixel_format" });
        @export(&frame.getOriginalPixelFormat, .{ .name = "turbores_frame_original_pixel_format" });
        @export(&frame.getAspectRatioNum, .{ .name = "turbores_frame_aspect_ratio_num" });
        @export(&frame.getAspectRatioDen, .{ .name = "turbores_frame_aspect_ratio_den" });
        @export(&frame.getColorPrimaries, .{ .name = "turbores_frame_color_primaries" });
        @export(&frame.getColorTransfer, .{ .name = "turbores_frame_color_transfer" });
        @export(&frame.getColorMatrix, .{ .name = "turbores_frame_color_matrix" });
        @export(&frame.getScanType, .{ .name = "turbores_frame_scan_type" });
    }
}
