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

/** Describes the pixel format of a decoded frame, including YUV chroma subsampling, bit depth, and alpha presence. */
export type PixelFormat = `I${'422' | '444'}${'' | 'A'}P${'10' | '12'}`;

/** The result of decoding a ProRes packet. */
export type DecodeResult = {
    /**
     * The raw data of the decoded frame, stored in the format described by `pixelFormat`. All frame data is stored in
     * YUV format.
     */
    frameData: Uint8Array;
    /** The coded width of the frame data in pixels. Always a multiple of 16. */
    codedWidth: number;
    /** The coded height of the frame data in pixels. Always a multiple of 16. */
    codedHeight: number;
    /**
     * The display width of the frame in pixels. May be smaller than `codedWidth`. The displayed rectangle always
     * starts in the top-left corner of the coded rectangle.
     */
    displayWidth: number;
    /**
     * The display height of the frame in pixels. May be smaller than `codedHeight`. The displayed rectangle always
     * starts in the top-left corner of the coded rectangle.
     */
    displayHeight: number;
    /** The pixel format of the decoded frame. */
    pixelFormat: PixelFormat;
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
    colorPrimaries: number;
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
    colorTransfer: number;
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
    colorMatrix: number;
    /**
     * Whether the decoded frame uses full range or limited range. ProRes always uses limited range, so this field
     * is always `false`.
     */
    colorRangeFull: false;
};

/** Per-packet decode options. */
export type DecodeOptions = {
    /**
     * Whether to transfer the `ArrayBuffer` that's backing the packet's data. There is no benefit to this when using
     * `DecoderOptions.useSharedMemory: true`, but when using the fallback path, this provides a speedup as it doesn't
     * need to copy the packet data to send it to the worker.
     */
    transfer?: boolean;
};

/** Options for creating a new `Decoder`. */
export type DecoderOptions = {
    /**
     * Whether to use shared-memory multithreading to speed up packet decoding. `true` is the preferred option and
     * provides the highest decode throughput and lowest latency while minimizing memory copies. Using it in browsers
     * requires that the `Cross-Origin-Opener-Policy` header be set to `same-origin` and the
     * `Cross-Origin-Embedder-Policy` header be set to `require-corp`.
     *
     * If you cannot set these headers, use `false` as a fallback. The decoder will still use multithreading but each
     * packet is only decoded by a single worker and more data has to be copied, meaning throughput and latency suffer.
     */
    useSharedMemory: boolean;
    /**
     * The number of threads to use for packet decoding. Defaults to `navigator.hardwareConcurrency`. Set this field to
     * `0` to use no workers and to enable synchronous decoding, which will block the thread.
     */
    concurrency?: number;
};

/**
 * A ProRes decoder instance. Use one `Decoder` instance per ProRes stream you want to decode. Create them using
 * `Decoder.create`.
 */
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

    /**
     * The number of decoding tasks that have been queued but have not yet been started. You can monitor this value
     * to apply backpressure if the decoder can't keep up with your supply of packets.
     */
    get decodeQueueSize() {
        return this._decodeQueueSize;
    }

    /**
     * Resolves whenever a packet queued for decoding starts being decoded. Use it in conjunction with
     * `decodeQueueSize` to apply backpressure.
     */
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

    /** Creates a new ProRes decoder instance with the given options. */
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
                'Shared memory is not available in this environment, so useSharedMemory: true cannot be used.\n'
                + 'Since it provides way better performance, you should enable it by serving the page cross-origin '
                + 'isolated by setting the Cross-Origin-Opener-Policy: same-origin and Cross-Origin-Embedder-Policy: '
                + 'require-corp response headers.\nOtherwise, pass useSharedMemory: false to use a slower, '
                + 'worker-based fallback.',
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

    /** Whether the environment supports proper shared-memory multithreading. */
    static async sharedMemoryIsAvailable() {
        return canUseSharedMemory;
    }

    /**
     * Queues a ProRes packet for decoding with the given options. Returns a promise that resolves either with a
     * `DecodeResult` containing the decoded frame or with an error that occurred.
     *
     * Decoded frames will always be emitted in the same order in which their packets were queued for decoding.
     */
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

    /** Closes this decoder and releases all internal resources once any queued packet decodes complete. */
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

    /** Whether this decoder has been closed. */
    get closed() {
        return this._closed;
    }

    /** Calls `.close()` internally. */
    [Symbol.dispose]() {
        // Synchronous disposal can't await; kick off close and let it finish in the background.
        void this.close();
    }

    /** Calls `.close()` internally. */
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

    protected async _runDecode(packetData: Uint8Array, options: DecodeOptions) {
        assert(this._runtime);
        const { exports, memory } = this._runtime;

        if (options.transfer) {
            // Unnecessary step, but makes it consistent in behavior with the other decoder
            packetData = structuredClone(packetData, { transfer: [packetData.buffer] });
        }

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
