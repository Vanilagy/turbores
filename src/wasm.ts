/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { decodeUtf8 } from './misc.js';

export type WasmExports = {
    __stack_pointer: WebAssembly.Global<'i32'>;
    __tls_align: WebAssembly.Global<'i32'>;
    __tls_base: WebAssembly.Global<'i32'>;
    __tls_size: WebAssembly.Global<'i32'>;
    __wasm_init_tls: (ptr: number) => void;

    setIsBrowserMainThread: (value: number) => void;
    allocateWorkerStack: () => number;
    allocateThreadLocalState: (size: number, alignment: number) => number;
    startWorker: () => never;
    getTaskStateAddress: (decoder: number) => number;
    createDecoder: (concurrency: number, bitDepth: number, allowedOutputFormats: number, log2Scale: number) => number;
    closeDecoder: (decoder: number) => void;
    createFrame: () => number;
    closeFrame: (frame: number) => void;
    allocatePacket: (decoder: number, size: number, slot: number) => number;
    decodePacket: (decoder: number, frame: number, slot: number) => number;
    decodeOnMainThread: (decoder: number, frame: number) => void;
    finalizePacketDecoding: (decoder: number) => number;
    getVisibleWidth: (frame: number) => number;
    getVisibleHeight: (frame: number) => number;
    getCodedWidth: (frame: number) => number;
    getCodedHeight: (frame: number) => number;
    getFrameDataPtr: (frame: number) => number;
    getFrameDataSize: (frame: number) => number;
    getFramePixelFormat: (frame: number) => number;
    getOriginalPixelFormat: (decoder: number) => number;
    getAspectRatioNum: (frame: number) => number;
    getAspectRatioDen: (frame: number) => number;
    getColorPrimaries: (frame: number) => number;
    getColorTransfer: (frame: number) => number;
    getColorMatrix: (frame: number) => number;
    getScanType: (frame: number) => number;
    getErrorMessagePtr: (decoder: number) => number;
    getErrorMessageSize: (decoder: number) => number;
};

export const initWasmModule = async (wasmBinary: Uint8Array<ArrayBuffer>, memory: WebAssembly.Memory) => {
    const { instance } = await WebAssembly.instantiate(wasmBinary, {
        env: {
            memory,
            externPrint: (offset: number, length: number) => {
                const bytes = new Uint8Array(memory.buffer, offset, length);
                console.log(decodeUtf8(bytes));
            },
        },
    });

    return instance.exports as WasmExports;
};
