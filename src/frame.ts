/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { FrameLockedError } from './errors.js';
import { assert } from './misc.js';
import type { SharedMemoryRuntime } from './runtime.js';
import type { WasmExports } from './wasm.js';

// Provide polyfills if needed
// @ts-expect-error Readonly
Symbol.dispose ??= Symbol('dispose');
// @ts-expect-error Readonly
Symbol.asyncDispose ??= Symbol('asyncDispose');

/** List of supported frame pixel formats. */
export const PIXEL_FORMATS = [
    // 4:2:0 Y, U, V
    'I420',
    'I420P10',
    'I420P12',
    // 4:2:0 Y, U, V, A
    'I420A',
    'I420AP10',
    'I420AP12',
    // 4:2:2 Y, U, V
    'I422',
    'I422P10',
    'I422P12',
    // 4:2:2 Y, U, V, A
    'I422A',
    'I422AP10',
    'I422AP12',
    // 4:4:4 Y, U, V
    'I444',
    'I444P10',
    'I444P12',
    // 4:4:4 Y, U, V, A
    'I444A',
    'I444AP10',
    'I444AP12',
] as const;

/**
 * Describes the pixel format of a decoded frame, including YUV chroma subsampling, bit depth, and alpha presence. The
 * strings are compatible with the WebCodecs API's `VideoPixelFormat`.
 */
export type PixelFormat = typeof PIXEL_FORMATS[number];

/**
 * Describes how a frame's lines are scanned: `'progressive'` means all lines are stored in a single pass, while the
 * interlaced types split the frame into two fields, with the suffix indicating which field comes first.
 */
export type ScanType = 'progressive' | 'interlaced-top-field-first' | 'interlaced-bottom-field-first';

// For automatic freeing of the WASM side
const frameRegistry = new FinalizationRegistry<{ runtime: SharedMemoryRuntime; ptr: number }>(({ runtime, ptr }) => {
    runtime.exports.closeFrame(ptr);
});

/**
 * A container for a decoded video frame. Pass a `Frame` to `Decoder.decode` to have it populated with the decoded
 * result. Reusing frames as much as possible minimizes memory usage because less frame buffers need to be allocated.
 *
 * Make sure to call `.clear()` on the frame when you're fully done using it.
 *
 * A `Frame` that is currently involved in a decoding task is considered _locked_ and using or closing it is an error.
 */
export class Frame implements Disposable {
    /**
     * The raw data of the decoded frame, stored in the format described by `pixelFormat`. All frame data is stored in
     * YUV format. This data becomes invalid as soon as the frame is used for its next decoding task.
     */
    frameData: Uint8Array | null = null;
    /** The coded width of the frame data in pixels. Always a multiple of 16. */
    codedWidth: number | null = null;
    /** The coded height of the frame data in pixels. Always a multiple of 16. */
    codedHeight: number | null = null;
    /**
     * The visible, displayed width of the frame in pixels. May be smaller than `codedWidth`. The visible rectangle
     * always starts in the top-left corner of the coded rectangle.
     */
    visibleWidth: number | null = null;
    /**
     * The visible, displayed height of the frame in pixels. May be smaller than `codedHeight`. The displayed rectangle
     * always starts in the top-left corner of the coded rectangle.
     */
    visibleHeight: number | null = null;
    /** The pixel format of this frame's data. */
    pixelFormat: PixelFormat | null = null;
    /**
     * The original frame pixel format as specified by the packet. If no conversion has taken place, this will match
     * {@link Frame.pixelFormat}.
     */
    originalPixelFormat: PixelFormat | null = null;
    /**
     * The color primaries of the decoded frame's color space. The values correspond to those defined in
     * ISO/IEC 23091-4:
     *
     * 0 - reserved \
     * 1 - ITU-R BT.709 \
     * 2 - unspecified \
     * 3 - reserved2 \
     * 4 - ITU-R BT.470M \
     * 5 - ITU-R BT.470BG - BT.601 625 \
     * 6 - ITU-R BT.601 525 - SMPTE 170M \
     * 7 - SMPTE 240M \
     * 8 - FILM \
     * 9 - ITU-R BT.2020 \
     * 10 - SMPTE ST 428-1 \
     * 11 - SMPTE RP 432-2 \
     * 12 - SMPTE EG 432-2 \
     * 22 - EBU Tech. 3213-E - JEDEC P22 phosphors
     */
    colorPrimaries: number | null = null;
    /**
     * The color transfer function of the decoded frame's color space. The values correspond to those defined in
     * ISO/IEC 23091-4:
     *
     * 0 - reserved \
     * 1 - ITU-R BT.709 \
     * 2 - unspecified \
     * 3 - reserved2 \
     * 4 - Gamma 2.2 curve - BT.470M \
     * 5 - Gamma 2.8 curve - BT.470BG \
     * 6 - SMPTE 170M \
     * 7 - SMPTE 240M \
     * 8 - Linear \
     * 9 - Log \
     * 10 - Log Sqrt \
     * 11 - IEC 61966-2-4 \
     * 12 - ITU-R BT.1361 Extended Colour Gamut \
     * 13 - IEC 61966-2-1 \
     * 14 - ITU-R BT.2020 10 bit \
     * 15 - ITU-R BT.2020 12 bit \
     * 16 - ITU-R BT.2100 Perceptual Quantization \
     * 17 - SMPTE ST 428-1 \
     * 18 - ARIB STD-B67 (HLG)
     */
    colorTransfer: number | null = null;
    /**
     * The matrix coefficients of the decoded frame's color space. The values correspond to those defined in
     * ISO/IEC 23001-8:
     *
     * 0 - Identity \
     * 1 - ITU-R BT.709 \
     * 2 - unspecified \
     * 3 - reserved \
     * 4 - US FCC 73.682 \
     * 5 - ITU-R BT.470BG \
     * 6 - SMPTE 170M \
     * 7 - SMPTE 240M \
     * 8 - YCoCg \
     * 9 - BT2020 Non-constant Luminance \
     * 10 - BT2020 Constant Luminance \
     * 11 - SMPTE ST 2085 \
     * 12 - Chroma-derived Non-constant Luminance \
     * 13 - Chroma-derived Constant Luminance \
     * 14 - ITU-R BT.2100-0
     */
    colorMatrix: number | null = null;
    /**
     * Whether the decoded frame uses full range or limited range. ProRes always uses limited range, so this field
     * is `false` whenever it is populated.
     */
    colorRangeFull: false | null = null;
    /**
     * How the frame's lines are scanned. `'progressive'` for a full-frame picture, or one of the interlaced types
     * when the frame is split into two fields (the suffix indicates which field comes first).
     */
    scanType: ScanType | null = null;

    /**
     * The runtime the WASM Frame lives on (shared-memory path).
     * @internal
     */
    _runtime: SharedMemoryRuntime | null = null;
    /**
     * Pointer to the WASM Frame (shared-memory path).
     * @internal
     */
    _ptr: number | null = null;
    /**
     * The recycled frame data buffer that ping-pongs between the main thread and a worker (message-passing path).
     * @internal
     */
    _buffer: ArrayBuffer | null = null;
    /** @internal */
    _locked = false;

    /** Whether this frame is locked by an in-flight decoding operation. While locked, it cannot be used or cleared. */
    get isLocked() {
        return this._locked;
    }

    /** Whether this frame contains decoded data, meaning all of its data fields are non-null. */
    get isFilled() {
        return this.frameData !== null
            && this.codedWidth !== null
            && this.codedHeight !== null
            && this.visibleWidth !== null
            && this.visibleHeight !== null
            && this.pixelFormat !== null
            && this.colorPrimaries !== null
            && this.colorTransfer !== null
            && this.colorMatrix !== null
            && this.colorRangeFull !== null
            && this.scanType !== null;
    }

    /** Returns this frame typed as a `FilledFrame` if it is filled, or `null` otherwise. */
    toFilled() {
        return this.isFilled ? this as FilledFrame : null;
    }

    /**
     * Clears this frame, resetting all of its fields and releasing all internal resources. The frame can still be
     * used again afterwards. Throws if the frame is locked.
     *
     * You *should always* call this method when you're done using a `Frame`. Not doing so may unnecessary bloat the
     * WASM memory and may even lead to out-of-memory errors.
     */
    clear() {
        if (this._locked) {
            throw new FrameLockedError();
        }

        if (this._ptr !== null) {
            assert(this._runtime);

            frameRegistry.unregister(this);
            this._runtime.exports.closeFrame(this._ptr);

            this._runtime = null;
            this._ptr = null;
        }

        this._buffer = null;
        this._reset();
    }

    /** Calls `.clear()` internally. */
    [Symbol.dispose]() {
        this.clear();
    }

    /** @internal */
    _ensureWasmFrame(runtime: SharedMemoryRuntime) {
        if (this._runtime === runtime) {
            return true;
        }

        if (this._runtime) {
            // The frame belongs to a different runtime; release it there first
            frameRegistry.unregister(this);
            this._runtime.exports.closeFrame(this._ptr!);

            this._runtime = null;
            this._ptr = null;
        }

        const ptr = runtime.exports.createFrame();
        if (ptr === 0) {
            return false;
        }

        this._runtime = runtime;
        this._ptr = ptr;
        frameRegistry.register(this, { runtime, ptr }, this);

        return true;
    }

    /** @internal */
    _reset() {
        this.frameData = null;
        this.codedWidth = null;
        this.codedHeight = null;
        this.visibleWidth = null;
        this.visibleHeight = null;
        this.pixelFormat = null;
        this.colorPrimaries = null;
        this.colorTransfer = null;
        this.colorMatrix = null;
        this.colorRangeFull = null;
        this.scanType = null;
    }

    /** @internal */
    _populate(contents: FrameContents) {
        this.frameData = contents.frameData;
        this.codedWidth = contents.codedWidth;
        this.codedHeight = contents.codedHeight;
        this.visibleWidth = contents.visibleWidth;
        this.visibleHeight = contents.visibleHeight;
        this.pixelFormat = contents.pixelFormat;
        this.originalPixelFormat = contents.originalPixelFormat;
        this.colorPrimaries = contents.colorPrimaries;
        this.colorTransfer = contents.colorTransfer;
        this.colorMatrix = contents.colorMatrix;
        this.colorRangeFull = contents.colorRangeFull;
        this.scanType = contents.scanType;
    }
}

/** A `Frame` that is known to be filled with decoded data, with `null` removed from all of its data fields. */
export type FilledFrame = {
    [K in keyof Frame]: NonNullable<Frame[K]>
};

export type FrameContents = {
    frameData: Uint8Array;
    codedWidth: number;
    codedHeight: number;
    visibleWidth: number;
    visibleHeight: number;
    pixelFormat: PixelFormat;
    originalPixelFormat: PixelFormat;
    colorPrimaries: number;
    colorTransfer: number;
    colorMatrix: number;
    colorRangeFull: false;
    scanType: ScanType;
};

export const readFrameContents = (
    exports: WasmExports,
    memory: WebAssembly.Memory,
    framePtr: number,
    decoderPtr: number,
): FrameContents => {
    const frameDataPtr = exports.getFrameDataPtr(framePtr);
    const frameDataSize = exports.getFrameDataSize(framePtr);
    const frameData = new Uint8Array(memory.buffer, frameDataPtr, frameDataSize);

    const pixelFormat = PIXEL_FORMATS[exports.getFramePixelFormat(framePtr)];
    assert(pixelFormat !== undefined);

    const originalPixelFormat = PIXEL_FORMATS[exports.getOriginalPixelFormat(decoderPtr)];
    assert(originalPixelFormat !== undefined);

    const scanType = ([
        'progressive',
        'interlaced-top-field-first',
        'interlaced-bottom-field-first',
    ] as const)[exports.getScanType(framePtr)];
    assert(scanType !== undefined);

    return {
        frameData,
        codedWidth: exports.getCodedWidth(framePtr),
        codedHeight: exports.getCodedHeight(framePtr),
        visibleWidth: exports.getVisibleWidth(framePtr),
        visibleHeight: exports.getVisibleHeight(framePtr),
        pixelFormat,
        originalPixelFormat,
        colorPrimaries: exports.getColorPrimaries(framePtr),
        colorTransfer: exports.getColorTransfer(framePtr),
        colorMatrix: exports.getColorMatrix(framePtr),
        colorRangeFull: false, // Always limited range, but expose it for clarity
        scanType,
    };
};
