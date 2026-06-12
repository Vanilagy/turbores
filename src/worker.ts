/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { ErrorCode } from './errors';
import { readFrameContents, type FrameContents } from './frame';
import { assert, decodeUtf8 } from './misc';
import { initWasmModule, type WasmExports } from './wasm';

export enum MessageType {
    SharedMemoryInit,
    MessagePassingInit,
    Decode,
    Ready,
    InitOutOfMemoryError,
    Decoded,
    DecodeError,
}

// Message sent to the worker
export type WorkerMessage =
    | {
        type: MessageType.SharedMemoryInit;
        wasmBinary: Uint8Array<ArrayBuffer>;
        memory: WebAssembly.Memory;
        stackPointer: number;
        tlsPointer: number;
    }
    | {
        type: MessageType.MessagePassingInit;
        wasmBinary: Uint8Array<ArrayBuffer>;
    }
    | {
        type: MessageType.Decode;
        id: number;
        packet: Uint8Array;
        frameBuffer: ArrayBuffer | null;
    };

// Message sent from the worker
export type WorkerReply =
    | {
        type: MessageType.Ready;
    }
    | {
        type: MessageType.InitOutOfMemoryError;
        message: string;
    }
    | {
        type: MessageType.Decoded;
        id: number;
        contents: FrameContents;
    }
    | {
        type: MessageType.DecodeError;
        id: number;
        code: number;
        message?: string;
    };

let messagePassingState: {
    exports: WasmExports;
    memory: WebAssembly.Memory;
    decoder: number;
    // Each worker only ever allocates a single WASM Frame, which it decodes every packet into
    frame: number;
} | null = null;

const onMessage = async (message: WorkerMessage) => {
    switch (message.type) {
        case MessageType.SharedMemoryInit: {
            const exports = await initWasmModule(message.wasmBinary, message.memory);
            exports.__stack_pointer.value = message.stackPointer;
            exports.__wasm_init_tls(message.tlsPointer);
            exports.setIsBrowserMainThread(Number(false));

            // Start the worker. This function will run forever.
            exports.startWorker();

            throw new Error('Unexpected worker termination.');
        }

        case MessageType.MessagePassingInit: {
            // Since we only ever use one decoder, 512 MiB should be plenty
            const memory = new WebAssembly.Memory({ initial: 32, maximum: 8192, shared: true });
            const exports = await initWasmModule(message.wasmBinary, memory);

            const tlsPointer = exports.allocateThreadLocalState(exports.__tls_size.value, exports.__tls_align.value);
            if (tlsPointer === 0) {
                sendMessage({
                    type: MessageType.InitOutOfMemoryError,
                    message: 'Failed to allocate thread-local state.',
                });

                return;
            }
            exports.__wasm_init_tls(tlsPointer);
            exports.setIsBrowserMainThread(Number(false));

            const decoder = exports.createDecoder(0); // Concurrent 0 = decode synchronously
            if (decoder === 0) {
                sendMessage({
                    type: MessageType.InitOutOfMemoryError,
                    message: 'Failed to create decoder.',
                });

                return;
            }

            const frame = exports.createFrame();
            if (frame === 0) {
                sendMessage({
                    type: MessageType.InitOutOfMemoryError,
                    message: 'Failed to create frame.',
                });

                return;
            }

            messagePassingState = { exports, memory, decoder, frame };
            sendMessage({ type: MessageType.Ready });

            return;
        }

        case MessageType.Decode: {
            assert(messagePassingState);
            const { exports, memory, decoder, frame } = messagePassingState;
            const { id, packet, frameBuffer: buffer } = message;

            const packetPtr = exports.allocatePacket(decoder, packet.byteLength);
            if (packetPtr === 0) {
                sendMessage({
                    type: MessageType.DecodeError,
                    id,
                    code: ErrorCode.OutOfMemory,
                });

                return;
            }
            new Uint8Array(memory.buffer).set(packet, packetPtr);

            const code = exports.decodePacket(decoder, frame);
            if (code < 0) {
                let errorMessage: string | undefined = undefined;
                const messagePtr = exports.getErrorMessagePtr(decoder);
                if (messagePtr !== 0) {
                    const size = exports.getErrorMessageSize(decoder);
                    errorMessage = decodeUtf8(new Uint8Array(memory.buffer, messagePtr, size));
                }

                sendMessage({
                    type: MessageType.DecodeError,
                    id,
                    code,
                    message: errorMessage,
                });

                return;
            }

            const contents = readFrameContents(exports, memory, frame);

            // Copy the frame data out of the WASM memory, reusing the buffer that was sent along
            // if it has the right size. Frames of constant size therefore cause no allocations:
            // their buffer just ping-pongs between this worker and the main thread.
            const outBuffer = buffer && buffer.byteLength === contents.frameData.byteLength
                ? buffer
                : new ArrayBuffer(contents.frameData.byteLength);
            const out = new Uint8Array(outBuffer);
            out.set(contents.frameData);
            contents.frameData = out;

            sendMessage({
                type: MessageType.Decoded,
                id,
                contents,
            }, [outBuffer]);

            return;
        }
    }
};

const sendMessage = (message: WorkerReply, transferables?: Transferable[]) => {
    if (parentPort) {
        parentPort.postMessage(message, transferables ?? []);
    } else {
        self.postMessage(message, { transfer: transferables ?? [] });
    }
};

// This file runs both as a web worker (browser, Deno) and as a node:worker_threads worker (Node, Bun), so hook up
// whichever messaging API the environment provides
let parentPort: {
    postMessage: (data: unknown, transferables?: Transferable[]) => void;
    on: (event: string, listener: (data: never) => void) => void;
} | null = null;

if (typeof self === 'undefined') {
    // eslint-disable-next-line @stylistic/max-len
    // eslint-disable-next-line @typescript-eslint/no-unsafe-assignment, @typescript-eslint/no-require-imports, @typescript-eslint/no-unsafe-member-access
    parentPort = require('node:worker_threads').parentPort;
}

if (parentPort) {
    // eslint-disable-next-line @typescript-eslint/no-misused-promises
    parentPort.on('message', onMessage);
} else {
    self.addEventListener('message', event => void onMessage(event.data as WorkerMessage));
}
