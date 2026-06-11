/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import {
    createErrorFromCodeAndMessage,
    DecoderClosedError,
    InvalidDataError,
    InvalidStateError,
    NotSupportedError,
    OutOfMemoryError,
    UnexpectedEofError,
} from './errors';
import { assert, decodeUtf8 } from './misc';
import { canUseSharedMemory, ensureWorkers, getConcurrency, getRuntime, type Runtime } from './runtime';
import type { WasmExports } from './wasm';
import type { WorkerMessage, WorkerReply } from './worker';

// Provide polyfills if needed
// @ts-expect-error Readonly
Symbol.dispose ??= Symbol('dispose');
// @ts-expect-error Readonly
Symbol.asyncDispose ??= Symbol('asyncDispose');

export type PixelFormat = `I${'422' | '444'}${'' | 'A'}P${'10' | '12'}`;

export type DecodeResult = {
    frameData: Uint8Array;
    codedWidth: number;
    codedHeight: number;
    displayWidth: number;
    displayHeight: number;
    pixelFormat: PixelFormat;
    colorPrimaries: number;
    colorTransfer: number;
    colorMatrix: number;
    colorRangeFull: boolean;
};

export type DecodeOptions = {
    transfer?: boolean;
};

export type DecoderOptions = {
    useSharedMemory: boolean;
    concurrency?: number;
};

export abstract class Decoder implements Disposable, AsyncDisposable {
    /** @internal */
    _closed = false;
    /** @internal */
    _queue: Promise<unknown> = Promise.resolve();
    /** @internal */
    readonly _concurrentDecode: boolean;
    /** @internal */
    _decodeQueueSize = 0;
    /** @internal */
    _dequeuedResolve!: () => void;
    /** @internal */
    _dequeued = new Promise<void>((resolve) => {
        this._dequeuedResolve = resolve;
    });

    protected constructor(concurrentDecode = false) {
        this._concurrentDecode = concurrentDecode;
    }

    get decodeQueueSize() {
        return this._decodeQueueSize;
    }

    get dequeued() {
        return this._dequeued;
    }

    /** @internal */
    _markDequeued() {
        this._decodeQueueSize--;

        this._dequeuedResolve();
        this._dequeued = new Promise<void>((resolve) => {
            this._dequeuedResolve = resolve;
        });
    }

    static async create(options: DecoderOptions) {
        if (typeof options !== 'object' || !options) {
            throw new TypeError('options must be an object.');
        }
        if (typeof options.useSharedMemory !== 'boolean') {
            throw new TypeError('options.useSharedMemory must be a boolean.');
        }
        if (
            options.concurrency !== undefined
            && (!Number.isInteger(options.concurrency) || options.concurrency < 0)
        ) {
            throw new TypeError('options.concurrency, when provided, must be a non-negative integer.');
        }

        if (options.useSharedMemory && !canUseSharedMemory) {
            return new NotSupportedError(
                'Shared memory is not available in this environment, so useSharedMemory: true cannot be used. '
                + 'To enable it, serve the page cross-origin isolated by setting the '
                + 'Cross-Origin-Opener-Policy: same-origin and Cross-Origin-Embedder-Policy: require-corp response '
                + 'headers. Otherwise, pass useSharedMemory: false to use the worker-based path.',
            );
        }

        const concurrency = options.concurrency ?? await getConcurrency();

        // Concurrency 0 means synchronous decoding on the calling thread
        if (options.useSharedMemory || concurrency === 0) {
            const runtime = await getRuntime();
            ensureWorkers(runtime, concurrency);

            const decoderPtr = runtime.exports.createDecoder(concurrency);
            if (decoderPtr === 0) {
                return new OutOfMemoryError();
            }

            return new SharedMemoryDecoder(runtime, decoderPtr, concurrency) as Decoder;
        }

        // No shared memory: spin up an independent pool of `concurrency` workers
        const results = await Promise.all(
            Array.from({ length: concurrency }, async () => {
                const worker = new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' });

                const reply = await new Promise<WorkerReply>((resolve) => {
                    worker.addEventListener('message', event => resolve(event.data as WorkerReply), { once: true });
                    worker.postMessage({ type: 'standalone-init' } satisfies WorkerMessage);
                });

                if (reply.type === 'init-error') {
                    worker.terminate();
                    return new OutOfMemoryError(reply.message);
                }

                return worker;
            }),
        );

        const failure = results.find((result): result is OutOfMemoryError => result instanceof Error);
        if (failure) {
            for (const result of results) {
                if (!(result instanceof Error)) {
                    result.terminate();
                }
            }

            return failure;
        }

        return new WorkerPoolDecoder(results as Worker[]) as Decoder;
    }

    static async sharedMemoryIsAvailable() {
        return canUseSharedMemory;
    }

    decode(packetData: Uint8Array, options: DecodeOptions = {}) {
        if (!(packetData instanceof Uint8Array)) {
            throw new TypeError('packetData must be a Uint8Array.');
        }
        if (typeof options !== 'object' || !options) {
            throw new TypeError('options must be an object.');
        }
        if (options.transfer !== undefined && typeof options.transfer !== 'boolean') {
            throw new TypeError('options.transfer, when provided, must be a boolean.');
        }

        if (this._closed) {
            return new DecoderClosedError();
        }

        this._decodeQueueSize++;
        const start = () => {
            this._markDequeued();
            return this._runDecode(packetData, options);
        };

        const work = this._concurrentDecode ? start() : null;
        const promise = this._queue.then(() => work ?? start());
        this._queue = promise.catch(() => {});

        return promise;
    }

    close() {
        if (this._closed) {
            // Idempotent, just resolve when the queue is done
            return this._queue as Promise<void>;
        }
        this._closed = true;

        const promise = this._queue.then(() => this._runClose());
        this._queue = promise.catch(() => {});

        return promise;
    }

    get closed() {
        return this._closed;
    }

    [Symbol.dispose]() {
        // Synchronous disposal can't await; kick off close and let it finish in the background.
        void this.close();
    }

    [Symbol.asyncDispose]() {
        return this.close();
    }

    /** @internal */
    protected abstract _runDecode(packetData: Uint8Array, options: DecodeOptions): Promise<
        DecodeResult | OutOfMemoryError | UnexpectedEofError | InvalidDataError | NotSupportedError | InvalidStateError
    >;
    /** @internal */
    protected abstract _runClose(): void | Promise<void>;
}

// For automatic freeing of the WASM side
const sharedMemoryDecoderRegistry = new FinalizationRegistry<{ runtime: Runtime; ptr: number }>(({ runtime, ptr }) => {
    runtime.exports.closeDecoder(ptr);
});

// Used when proper shared memory is available
class SharedMemoryDecoder extends Decoder {
    /** @internal */
    _runtime: Runtime | null;
    /** @internal */
    _ptr: number;
    /** @internal */
    _waitWordAddress: number;
    /**
     * 0 means decodePacket runs synchronously in the main thread
     * @internal
     */
    _concurrency: number;

    constructor(runtime: Runtime, ptr: number, concurrency: number) {
        super();
        this._runtime = runtime;
        this._ptr = ptr;
        this._waitWordAddress = runtime.exports.getWaitWordAddress(ptr);
        this._concurrency = concurrency;

        sharedMemoryDecoderRegistry.register(this, { runtime, ptr }, this);
    }

    protected _runClose() {
        assert(this._runtime);

        sharedMemoryDecoderRegistry.unregister(this);
        this._runtime.exports.closeDecoder(this._ptr);

        this._runtime = null; // Allow it to get GCd if necessary
    }

    protected async _runDecode(packetData: Uint8Array) {
        assert(this._runtime);
        const { exports, memory } = this._runtime;

        const packetPtr = exports.allocatePacket(this._ptr, packetData.byteLength);
        if (packetPtr === 0) {
            return new OutOfMemoryError();
        }
        new Uint8Array(memory.buffer).set(packetData, packetPtr);

        let resultCode = exports.decodePacket(this._ptr);
        if (resultCode < 0) {
            return this._createError(resultCode);
        }

        if (this._concurrency > 0) {
            // Wait for all workers to finish
            await Atomics.waitAsync(new Int32Array(memory.buffer), this._waitWordAddress / 4, 0).value;

            resultCode = exports.finalizePacketDecoding(this._ptr);
            if (resultCode < 0) {
                return this._createError(resultCode);
            }
        }

        return buildDecodeResult(exports, memory, this._ptr);
    }

    /** @internal */
    _createError(code: number) {
        assert(this._runtime);
        const { exports, memory } = this._runtime;

        let errorMessage: string | undefined = undefined;

        const messagePtr = exports.getErrorMessagePtr(this._ptr);
        if (messagePtr !== 0) {
            const size = exports.getErrorMessageSize(this._ptr);
            errorMessage = decodeUtf8(new Uint8Array(memory.buffer, messagePtr, size));
        }

        return createErrorFromCodeAndMessage(code, errorMessage);
    }
}

// Used when shared memory is not available. Each worker owns an independent decoder, and packets
// are spread across them so multiple can decode in parallel.
class WorkerPoolDecoder extends Decoder {
    /** @internal */
    _workers: Worker[];
    /**
     * How many packets each worker currently has in flight
     * @internal
     */
    _workerLoad: number[];
    /** @internal */
    _nextRequestId = 0;

    constructor(workers: Worker[]) {
        super(true);
        this._workers = workers;
        this._workerLoad = workers.map(() => 0);
    }

    protected _runClose() {
        for (const worker of this._workers) {
            worker.terminate();
        }
    }

    protected _runDecode(packetData: Uint8Array, options: DecodeOptions) {
        const packet = options.transfer ? packetData : packetData.slice();

        // Hand the packet to the first worker with the lowest load
        let workerIndex = 0;
        for (let i = 1; i < this._workerLoad.length; i++) {
            if (this._workerLoad[i]! < this._workerLoad[workerIndex]!) {
                workerIndex = i;
            }
        }

        const worker = this._workers[workerIndex]!;
        this._workerLoad[workerIndex] = this._workerLoad[workerIndex]! + 1;

        const id = this._nextRequestId++;

        return new Promise<
            | DecodeResult | OutOfMemoryError | UnexpectedEofError
            | InvalidDataError | NotSupportedError | InvalidStateError
        >((resolve) => {
            worker.postMessage(
                { type: 'decode', id, packet } satisfies WorkerMessage,
                { transfer: [packet.buffer] },
            );

            const onMessage = (event: MessageEvent) => {
                const reply = event.data as WorkerReply;
                if (reply.type !== 'decoded' && reply.type !== 'decode-error') {
                    return;
                }
                if (reply.id !== id) {
                    return;
                }

                worker.removeEventListener('message', onMessage);
                this._workerLoad[workerIndex]!--;

                if (reply.type === 'decode-error') {
                    resolve(createErrorFromCodeAndMessage(reply.code, reply.message));
                } else {
                    resolve(reply.result);
                }
            };
            worker.addEventListener('message', onMessage);
        });
    }
}

export const buildDecodeResult = (exports: WasmExports, memory: WebAssembly.Memory, ptr: number): DecodeResult => {
    const frameDataPtr = exports.getFrameDataPtr(ptr);
    const frameDataSize = exports.getFrameDataSize(ptr);
    const frameData = new Uint8Array(memory.buffer, frameDataPtr, frameDataSize * 2);

    const chroma = exports.getChromaSubsampling(ptr);
    const alpha = exports.getAlphaBitDepth(ptr) !== 0 ? 'A' : '';
    const bitDepth = exports.getBitDepth(ptr);
    const pixelFormat = `I${chroma}${alpha}P${bitDepth}` as PixelFormat;

    return {
        frameData,
        codedWidth: exports.getCodedWidth(ptr),
        codedHeight: exports.getCodedHeight(ptr),
        displayWidth: exports.getDisplayWidth(ptr),
        displayHeight: exports.getDisplayHeight(ptr),
        pixelFormat,
        colorPrimaries: exports.getColorPrimaries(ptr),
        colorTransfer: exports.getColorTransfer(ptr),
        colorMatrix: exports.getColorMatrix(ptr),
        colorRangeFull: false, // Always limited range, but expose it for clarity
    };
};
