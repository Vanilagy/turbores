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
    FrameLockedError,
    InvalidDataError,
    InvalidStateError,
    NotSupportedError,
    OutOfMemoryError,
    UnexpectedEofError,
} from './errors.js';
import { Frame, PIXEL_FORMATS, PixelFormat, readFrameContents, type FilledFrame } from './frame.js';
import { MessageType, type WorkerMessage, type WorkerReply } from './messages.js';
import { assert, AsyncMutex, canUseSharedMemory, decodeUtf8 } from './misc.js';
import {
    getConcurrency,
    getSharedMemoryRuntime,
    getMessagePassingRuntime,
    type SharedMemoryRuntime,
    type MessagePassingRuntime,
} from './runtime.js';

const PRORES_FOURCCS = [
    'ap4x', // ProRes 4444 XQ
    'ap4h', // ProRes 4444
    'apch', // ProRes 422 High Quality
    'apcn', // ProRes 422 Standard Definition
    'apcs', // ProRes 422 LT
    'apco', // ProRes 422 Proxy
];

/**
 * Options for creating a new `Decoder`.
 * @public
 */
export type DecoderOptions = {
    /**
     * The FourCC indicating the ProRes variant. This is typically found in the container file containing the ProRes
     * media. When this is not available, `'apch'` is a safe option for 10-bit output. `'ap4x'` and `'ap4h'` provide
     * 12-bit output.
     */
    proresFourCc: 'ap4x' | 'ap4h' | 'apch' | 'apcn' | 'apcs' | 'apco';
    /**
     * Whether to use shared-memory multithreading to speed up packet decoding. `true` is the preferred option and
     * provides the highest decode throughput and lowest latency while minimizing memory copies. Using it in browsers
     * requires that the `Cross-Origin-Opener-Policy` header be set to `same-origin` and the
     * `Cross-Origin-Embedder-Policy` header be set to `credentialless` or `require-corp` (only the latter is supported
     * by Safari).
     *
     * If you cannot set these headers, use `false` as a fallback. The decoder will still use multithreading but each
     * packet is only decoded by a single worker and more data has to be copied, meaning throughput and latency suffer.
     *
     * If you don't know ahead of time and want to be environment-agnostic, use `Decoder.canUseSharedMemory`.
     */
    useSharedMemory: boolean;
    /**
     * The number of threads to use for packet decoding. Defaults to `navigator.hardwareConcurrency`. Set this field to
     * `0` to use no workers and to enable synchronous decoding, which will block the thread.
     */
    concurrency?: number;
    /**
     * A non-empty list of frame pixel formats that, when provided, the decoder *must* output. Can be used to limit the
     * pixel formats the decoder emits to only those formats that your downstream code can handle.
     *
     * When omitted, frames will always be emitted in their native pixel format as indicated in the ProRes packet.
     *
     * When the frame's native format is not present in this list, the decoder will first try to choose an alternative
     * format that avoids data loss. If none are available, it will try to pick the best format with the least amount
     * of loss, preferring maintaining bit depth over chroma resolution.
     */
    allowedOutputFormats?: PixelFormat[];
    /**
     * Decodes the video at a reduced resolution for extra speed. Must be one of `1` (full resolution, the default),
     * `2`, `4` or `8`, producing frames at 1, 1/2, 1/4 or 1/8 of the source dimensions in each axis.
     *
     * This is not a post-decode resize: the decoder runs a smaller inverse DCT over only the low-frequency
     * coefficients of each block, so no separate resampling step is performed and less work is done overall (at scale
     * `8`, the high-frequency coefficient stream is skipped entirely). The result is a clean, correctly-aligned
     * downscale, ideal for fast previews, scrubbing, or generating thumbnails.
     *
     * When `scale` is greater than `1`, frames are always emitted in their native pixel format; `allowedOutputFormats`
     * is not applied, as downscaling does not combine with pixel-format conversion. Downscaled decoding is also not
     * supported for interlaced content.
     */
    scale?: 1 | 2 | 4 | 8;
};

/**
 * Per-packet decode options.
 * @public
 */
export type DecodeOptions = {
    /**
     * Whether to transfer the `ArrayBuffer` that's backing the packet's data. There is no benefit to this when using
     * `DecoderOptions.useSharedMemory: true`, but when using the fallback path, this provides a speedup as it doesn't
     * need to copy the packet data to send it to the worker.
     */
    transfer?: boolean;
};

/**
 * A ProRes decoder instance. Use one `Decoder` instance per ProRes stream you want to decode. Create them using
 * `Decoder.create`.
 * @public
 */
export abstract class Decoder implements Disposable, AsyncDisposable {
    /** @internal */
    _closed = false;
    /** @internal */
    _queue: Promise<unknown> = Promise.resolve();
    /** @internal */
    _decodeQueueSize = 0;
    /** @internal */
    _dequeuedResolve!: () => void;
    /** @internal */
    _dequeued = new Promise<void>((resolve) => {
        this._dequeuedResolve = resolve;
    });

    /** @internal */
    abstract readonly _highWaterMark: number;

    /** Whether this decodes makes use of shared-memory multithreading. Specified in the decoder options. */
    abstract readonly useSharedMemory: boolean;
    /**
     * The number of threads that are used for packet decoding, as specified in the decoder options. A value of `0`
     * means the decoding happens synchronously.
     */
    abstract readonly concurrency: number;

    /**
     * The number of decoding tasks that have been queued but have not yet finished. You can monitor this value
     * to apply backpressure if the decoder can't keep up with your supply of packets.
     */
    get decodeQueueSize() {
        return this._decodeQueueSize;
    }

    /**
     * The number of additional packets that can be queued for decoding before the decoder's internal high-water mark
     * is reached, mirroring `desiredSize` from the Web Streams API. Keep queuing packets while this is positive to
     * make the most of the decoder performance-wise.
     */
    get desiredSize() {
        return this._highWaterMark - this._decodeQueueSize;
    }

    /**
     * Resolves whenever a packet queued for decoding finishes decoding. Use it in conjunction with
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
        if (!PRORES_FOURCCS.includes(options.proresFourCc)) {
            throw new TypeError(`options.proresFourCc must be one of ${PRORES_FOURCCS.join(', ')}.`);
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
        if (options.allowedOutputFormats && !(
            Array.isArray(options.allowedOutputFormats)
            && options.allowedOutputFormats.length > 0
            && options.allowedOutputFormats.every(x => PIXEL_FORMATS.includes(x))
        )) {
            throw new TypeError(
                `options.allowedOutputFormats, when provided, must be a non-empty array containing any of: `
                + `${PIXEL_FORMATS.join(', ')}.`,
            );
        }
        if (options.scale !== undefined && options.scale !== 1 && options.scale !== 2
            && options.scale !== 4 && options.scale !== 8) {
            throw new TypeError('options.scale, when provided, must be one of 1, 2, 4 or 8.');
        }

        if (options.useSharedMemory && !canUseSharedMemory) {
            return new NotSupportedError(
                'Shared memory is not available in this environment, so useSharedMemory: true cannot be used.\n'
                + 'Since it provides way better performance, you should enable it by serving the page cross-origin '
                + 'isolated by setting the Cross-Origin-Opener-Policy header to \'same-origin\' and the '
                + 'Cross-Origin-Embedder-Policy header to \'credentialless\' or \'require-corp\' (only the latter is '
                + 'supported by Safari).\nOtherwise, pass useSharedMemory: false to use a slower, '
                + 'worker-based fallback.',
            );
        }

        // Build a bit field containing the list if allowed output formats
        let allowedOutputFormatsBitfield: number;
        if (options.allowedOutputFormats) {
            allowedOutputFormatsBitfield = 0;
            for (const format of options.allowedOutputFormats) {
                allowedOutputFormatsBitfield |= 1 << PIXEL_FORMATS.indexOf(format);
            }
        } else {
            allowedOutputFormatsBitfield = 0xffffffff;
        }

        const bitDepth = options.proresFourCc === 'ap4h' || options.proresFourCc === 'ap4x'
            ? 12
            : 10;
        const log2Scale = Math.log2(options.scale ?? 1); // 1/2/4/8 -> 0/1/2/3
        const concurrency = options.concurrency ?? await getConcurrency();

        // Concurrency 0 always uses the shared memory runtime, since that's the only one with a WASM instance on the
        // main thread
        if (options.useSharedMemory || concurrency === 0) {
            const runtime = await getSharedMemoryRuntime();
            runtime.ref();

            await runtime.ensureWorkers(concurrency);

            const decoderPtr = runtime.exports.createDecoder(
                concurrency,
                bitDepth,
                allowedOutputFormatsBitfield,
                log2Scale,
            );
            if (decoderPtr === 0) {
                runtime.unref();
                return new OutOfMemoryError();
            }

            return new SharedMemoryDecoder(runtime, decoderPtr, concurrency) as Decoder;
        } else {
            // No shared memory: use the message-passing runtime
            const runtime = getMessagePassingRuntime();
            runtime.ref();

            const failure = await runtime.ensureWorkers(concurrency);
            if (failure) {
                runtime.unref();
                return failure;
            }

            return new MessagePassingDecoder(
                runtime,
                concurrency,
                bitDepth,
                allowedOutputFormatsBitfield,
                log2Scale,
            ) as Decoder;
        }
    }

    /** Whether the environment supports proper shared-memory multithreading. */
    static canUseSharedMemory() {
        return canUseSharedMemory;
    }

    /**
     * Queues a ProRes packet for decoding with the given options. The decoded result will be stored in the passed
     * frame. Returns a promise that resolves either with the populated frame or with an error that occurred.
     *
     * Decoded frames will always be emitted in the same order in which their packets were queued for decoding.
     */
    async decode(packetData: Uint8Array, frame: Frame, options: DecodeOptions = {}) {
        if (!(packetData instanceof Uint8Array)) {
            throw new TypeError('packetData must be a Uint8Array.');
        }
        if (!(frame instanceof Frame)) {
            throw new TypeError('frame must be a Frame.');
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
        if (frame._locked) {
            return new FrameLockedError();
        }

        // Lock the frame while the decoding is going
        frame._reset();
        frame._locked = true;

        this._decodeQueueSize++;

        const work = this._runDecode(packetData, frame, options);
        work.catch(() => {}); // So that the error doesn't surface before `then` is called further down

        // Make sure the promises resolve in the same order in which they were queued
        const promise = this._queue
            .then(() => work)
            .finally(() => {
                frame._locked = false;

                // Queue a microtask so that the dequeue promise gets resolved AFTER this promise gets resolved
                queueMicrotask(() => {
                    this._decodeQueueSize--;

                    this._dequeuedResolve();
                    this._dequeued = new Promise<void>((resolve) => {
                        this._dequeuedResolve = resolve;
                    });
                });
            });
        this._queue = promise.catch(() => {});

        return promise;
    }

    /** Closes this decoder and releases all internal resources once all queued packet decodes complete. */
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
    get isClosed() {
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
    protected abstract _runDecode(packetData: Uint8Array, frame: Frame, options: DecodeOptions): Promise<
        FilledFrame | OutOfMemoryError | UnexpectedEofError | InvalidDataError | NotSupportedError | InvalidStateError
    >;
    /** @internal */
    protected abstract _runClose(): void | Promise<void>;
}

// For automatic freeing of the WASM side
const sharedMemoryDecoderRegistry = new FinalizationRegistry<{ runtime: SharedMemoryRuntime; ptr: number }>(
    ({ runtime, ptr }) => {
        runtime.exports.closeDecoder(ptr);
        runtime.unref();
    },
);

// Used when proper shared memory is available
class SharedMemoryDecoder extends Decoder {
    /** @internal */
    _runtime: SharedMemoryRuntime | null;
    /** @internal */
    _decoderPtr: number;
    /** @internal */
    _taskStateOffset: number;
    /** @internal */
    _decodeMutex = new AsyncMutex();
    /** @internal */
    _nextPacketSlot = 0;
    /** @internal */
    _packetSlotMutexes = [new AsyncMutex(), new AsyncMutex()];

    /** @internal */
    override readonly _highWaterMark: number;

    override readonly useSharedMemory = true;
    override readonly concurrency: number;

    constructor(runtime: SharedMemoryRuntime, ptr: number, concurrency: number) {
        super();

        this._highWaterMark = concurrency === 0 ? 1 : 2;
        this._runtime = runtime;
        this._decoderPtr = ptr;
        this._taskStateOffset = runtime.exports.getTaskStateAddress(ptr) / 4;
        this.concurrency = concurrency;

        sharedMemoryDecoderRegistry.register(this, { runtime, ptr }, this);
    }

    protected _runClose() {
        assert(this._runtime);

        sharedMemoryDecoderRegistry.unregister(this);
        this._runtime.exports.closeDecoder(this._decoderPtr);
        this._runtime.unref();

        this._runtime = null; // Allow it to get GCd if necessary
    }

    protected async _runDecode(packetData: Uint8Array, frame: Frame, options: DecodeOptions) {
        assert(this._runtime);
        const { exports, memory } = this._runtime;

        if (!frame._ensureWasmFrame(this._runtime)) {
            return new OutOfMemoryError();
        }

        const framePtr = frame._ptr!;

        if (options.transfer) {
            // Unnecessary step, but makes it consistent in behavior with the other decoder
            packetData = structuredClone(packetData, { transfer: [packetData.buffer] });
        }

        const packetSlot = this._nextPacketSlot;
        this._nextPacketSlot = (this._nextPacketSlot + 1) & 1;

        const releasePacket = await this._packetSlotMutexes[packetSlot]!.acquire();

        try {
            const packetPtr = exports.allocatePacket(this._decoderPtr, packetData.byteLength, packetSlot);
            if (packetPtr === 0) {
                return new OutOfMemoryError();
            }
            new Uint8Array(memory.buffer).set(packetData, packetPtr);

            const releaseDecode = await this._decodeMutex.acquire();

            try {
                let resultCode = exports.decodePacket(this._decoderPtr, framePtr, packetSlot);
                if (resultCode < 0) {
                    return this._createError(resultCode);
                }

                if (this.concurrency > 0) {
                    // Unless more packets are queued (in which case the main thread is better used feeding the
                    // pipeline), help decode instead of idling until the workers finish.
                    if (this._decodeQueueSize <= 1) {
                        exports.decodeOnMainThread(this._decoderPtr, framePtr);
                    }

                    // Wait for all workers to finish. We wait on the "working" state (1); if the workers already
                    // finished and stored "done" (0), waitAsync returns immediately.
                    await Atomics.waitAsync(new Int32Array(memory.buffer), this._taskStateOffset, 1).value;

                    resultCode = exports.finalizePacketDecoding(this._decoderPtr);
                    if (resultCode < 0) {
                        return this._createError(resultCode);
                    }
                }

                // The frame data is not copied; it's a direct view into the WASM memory
                frame._populate(readFrameContents(exports, memory, framePtr, this._decoderPtr));
            } finally {
                releaseDecode();
            }
        } finally {
            releasePacket();
        }

        return frame as FilledFrame;
    }

    /** @internal */
    _createError(code: number) {
        assert(this._runtime);
        const { exports, memory } = this._runtime;

        let errorMessage: string | undefined = undefined;

        const messagePtr = exports.getErrorMessagePtr(this._decoderPtr);
        if (messagePtr !== 0) {
            const size = exports.getErrorMessageSize(this._decoderPtr);
            errorMessage = decodeUtf8(new Uint8Array(memory.buffer, messagePtr, size));
        }

        return createErrorFromCodeAndMessage(code, errorMessage);
    }
}

// For automatic releasing of the runtime
const messagePassingDecoderRegistry = new FinalizationRegistry<MessagePassingRuntime>((runtime) => {
    runtime.unref();
});

// Used when shared memory is not available. Each of the runtime's workers owns an independent decoder, and packets are
// spread across them so multiple can decode in parallel.
class MessagePassingDecoder extends Decoder {
    /** @internal */
    _runtime: MessagePassingRuntime | null;
    /** @internal */
    _decoderId: number;

    /** @internal */
    override readonly _highWaterMark: number;

    override readonly useSharedMemory = false;
    override readonly concurrency: number;

    constructor(
        runtime: MessagePassingRuntime,
        concurrency: number,
        bitDepth: number,
        allowedOutputFormats: number,
        log2Scale: number,
    ) {
        super();

        this._highWaterMark = Math.max(concurrency, 1);
        this._runtime = runtime;
        this.concurrency = concurrency;
        this._decoderId = runtime.nextDecoderId++;

        // Spin up our own decoder on every worker; the workers are shared across decoder instances
        runtime.registerDecoder(this._decoderId, bitDepth, allowedOutputFormats, log2Scale);

        messagePassingDecoderRegistry.register(this, runtime, this);
    }

    protected _runClose() {
        assert(this._runtime);

        this._runtime.unregisterDecoder(this._decoderId);

        messagePassingDecoderRegistry.unregister(this);
        this._runtime.unref();

        this._runtime = null; // Allow it to get GCd if necessary
    }

    protected _runDecode(packetData: Uint8Array, frame: Frame, options: DecodeOptions) {
        assert(this._runtime);
        const runtime = this._runtime;

        const packet = options.transfer ? packetData : packetData.slice();

        // Hand the packet to the first worker with the lowest load
        let workerIndex = 0;
        for (let i = 1; i < runtime.workerLoad.length; i++) {
            if (runtime.workerLoad[i]! < runtime.workerLoad[workerIndex]!) {
                workerIndex = i;
            }
        }

        const worker = runtime.workers[workerIndex]!;
        runtime.workerLoad[workerIndex] = runtime.workerLoad[workerIndex]! + 1;

        const id = runtime.nextRequestId++;

        // Send the frame's recycled buffer along so the worker can decode into it without
        // allocating anything new
        const frameBuffer = frame._buffer;
        frame._buffer = null;

        return new Promise<
            | FilledFrame | OutOfMemoryError | UnexpectedEofError
            | InvalidDataError | NotSupportedError | InvalidStateError
        >((resolve) => {
            worker.postMessage(
                {
                    type: MessageType.Decode,
                    id,
                    decoderId: this._decoderId,
                    packet,
                    frameBuffer,
                } satisfies WorkerMessage,
                frameBuffer ? [packet.buffer, frameBuffer] : [packet.buffer],
            );

            const onMessage = (event: { data: unknown }) => {
                const reply = event.data as WorkerReply;
                if (reply.type !== MessageType.Decoded && reply.type !== MessageType.DecodeError) {
                    return;
                }
                if (reply.id !== id) {
                    return;
                }

                worker.removeEventListener('message', onMessage);
                runtime.workerLoad[workerIndex]!--;

                if (reply.type === MessageType.DecodeError) {
                    resolve(createErrorFromCodeAndMessage(reply.code, reply.message));
                } else {
                    frame._buffer = reply.contents.frameData.buffer as ArrayBuffer;
                    frame._populate(reply.contents);
                    resolve(frame as FilledFrame);
                }
            };
            worker.addEventListener('message', onMessage);
        });
    }
}
