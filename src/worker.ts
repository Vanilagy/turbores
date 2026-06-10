import { buildDecodeResult } from './decoder';
import { ErrorCode } from './errors';
import { assert, decodeUtf8 } from './misc';
import { initWasmModule, type WasmExports } from './wasm';

let standaloneState: {
    exports: WasmExports;
    memory: WebAssembly.Memory;
    decoder: number;
} | null = null;

self.addEventListener('message', async (event) => {
    const message = event.data as WorkerMessage;

    switch (message.type) {
        case 'shared-worker': {
            const exports = await initWasmModule(message.memory);
            exports.__stack_pointer.value = message.stackPointer;
            exports.__wasm_init_tls(message.tlsPointer);
            exports.setIsBrowserMainThread(Number(false));

            // Start the worker. This function will run forever.
            exports.startWorker();

            throw new Error('Unexpected worker termination.');
        }

        case 'standalone-init': {
            // Since we only ever use one decoder, 512 MiB should be plenty
            const memory = new WebAssembly.Memory({ initial: 32, maximum: 8192, shared: true });
            const exports = await initWasmModule(memory);

            const tlsPointer = exports.allocateThreadLocalState(exports.__tls_size.value, exports.__tls_align.value);
            if (tlsPointer === 0) {
                self.postMessage({ type: 'init-error', message: 'Failed to allocate thread-local state.' });
                return;
            }
            exports.__wasm_init_tls(tlsPointer);
            exports.setIsBrowserMainThread(Number(false));

            const decoder = exports.createDecoder(0); // Concurrent 0 = decode synchronously
            if (decoder === 0) {
                self.postMessage({ type: 'init-error', message: 'Failed to create decoder.' });
                return;
            }

            standaloneState = { exports, memory, decoder };
            self.postMessage({ type: 'ready' });

            return;
        }

        case 'decode': {
            assert(standaloneState);
            const { exports, memory, decoder } = standaloneState;
            const packet = message.packet;

            const packetPtr = exports.allocatePacket(decoder, packet.byteLength);
            if (packetPtr === 0) {
                self.postMessage({ type: 'decode-error', code: ErrorCode.OutOfMemory });
                return;
            }
            new Uint8Array(memory.buffer).set(packet, packetPtr);

            const code = exports.decodePacket(decoder);
            if (code < 0) {
                let errorMessage: string | undefined = undefined;
                const messagePtr = exports.getErrorMessagePtr(decoder);
                if (messagePtr !== 0) {
                    const size = exports.getErrorMessageSize(decoder);
                    errorMessage = decodeUtf8(new Uint8Array(memory.buffer, messagePtr, size));
                }

                self.postMessage({ type: 'decode-error', code, message: errorMessage });
                return;
            }

            const result = buildDecodeResult(exports, memory, decoder);
            result.frameData = result.frameData.slice();

            self.postMessage(
                { type: 'decoded', result },
                { transfer: [result.frameData.buffer] },
            );
            
            return;
        }
    }
});

import type { DecodeResult } from './decoder';

// Message sent to the worker
export type WorkerMessage =
    | { type: 'shared-worker'; memory: WebAssembly.Memory; stackPointer: number; tlsPointer: number }
    | { type: 'standalone-init' }
    | { type: 'decode'; packet: Uint8Array };

// Message sent from the worker
export type WorkerReply =
    | { type: 'ready' }
    | { type: 'init-error'; message: string }
    | { type: 'decoded'; result: DecodeResult }
    | { type: 'decode-error'; code: number; message?: string };
