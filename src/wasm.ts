/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import initWasm from '../build/lib.wasm?init';
import { decodeUtf8 } from './misc';

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
    getWaitWordAddress: (decoder: number) => number;
    createDecoder: (concurrency: number) => number;
    closeDecoder: (decoder: number) => void;
    allocatePacket: (decoder: number, size: number) => number;
    decodePacket: (decoder: number) => number;
    finalizePacketDecoding: (decoder: number) => number;
    getDisplayWidth: (decoder: number) => number;
    getDisplayHeight: (decoder: number) => number;
    getCodedWidth: (decoder: number) => number;
    getCodedHeight: (decoder: number) => number;
    getFrameDataPtr: (decoder: number) => number;
    getFrameDataSize: (decoder: number) => number;
    getChromaSubsampling: (decoder: number) => number;
    getBitDepth: (decoder: number) => number;
    getAlphaBitDepth: (decoder: number) => number;
    getColorPrimaries: (decoder: number) => number;
    getColorTransfer: (decoder: number) => number;
    getColorMatrix: (decoder: number) => number;
    getErrorMessagePtr: (decoder: number) => number;
    getErrorMessageSize: (decoder: number) => number;
};

export const initWasmModule = async (memory: WebAssembly.Memory) => {
    const instance = await initWasm({
        env: {
            memory,
            externPrint: (offset: number, length: number) => {
                const bytes = new Uint8Array(memory.buffer, offset, length);
                console.log(decodeUtf8(bytes));
            },
        },
    });

    return instance.exports as unknown as WasmExports;
};
