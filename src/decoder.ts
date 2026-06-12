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
import { Frame, readFrameContents, type FilledFrame } from './frame.js';
import { MessageType, type WorkerMessage, type WorkerReply } from './messages.js';
import { assert, canUseSharedMemory, decodeUtf8 } from './misc.js';
import {
    getConcurrency,
    getSharedMemoryRuntime,
    getMessagePassingRuntime,
    type SharedMemoryRuntime,
    type MessagePassingRuntime,
} from './runtime.js';

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
                + 'isolated by setting the Cross-Origin-Opener-Policy header to \'same-origin\' and the '
                + 'Cross-Origin-Embedder-Policy header to \'credentialless\' or \'require-corp\' (only the latter is '
                + 'supported by Safari).\nOtherwise, pass useSharedMemory: false to use a slower, '
                + 'worker-based fallback.',
            );
        }

        const concurrency = options.concurrency ?? await getConcurrency();

        // Concurrency 0 always uses the shared memory runtime, since that's the only one with a WASM instance on the
        // main thread
        if (options.useSharedMemory || concurrency === 0) {
            const runtime = await getSharedMemoryRuntime();
            runtime.ref();

            await runtime.ensureWorkers(concurrency);

            const decoderPtr = runtime.exports.createDecoder(concurrency);
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

            return new MessagePassingDecoder(runtime) as Decoder;
        }
    }

    /** Whether the environment supports proper shared-memory multithreading. */
    static sharedMemoryIsAvailable() {
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
        const start = () => {
            this._markDequeued();
            return this._runDecode(packetData, frame, options);
        };

        const work = this._concurrentDecode ? start() : null;
        const promise = this._queue
            .then(() => work ?? start())
            .finally(() => {
                frame._locked = false;
            });
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
    _ptr: number;
    /** @internal */
    _waitWordAddress: number;
    /**
     * 0 means decodePacket runs synchronously in the main thread
     * @internal
     */
    _concurrency: number;

    constructor(runtime: SharedMemoryRuntime, ptr: number, concurrency: number) {
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

        const packetPtr = exports.allocatePacket(this._ptr, packetData.byteLength);
        if (packetPtr === 0) {
            return new OutOfMemoryError();
        }
        new Uint8Array(memory.buffer).set(packetData, packetPtr);

        let resultCode = exports.decodePacket(this._ptr, framePtr);
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

        // The frame data is not copied; it's a direct view into the WASM memory
        frame._populate(readFrameContents(exports, memory, framePtr));
        return frame as FilledFrame;
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

// For automatic releasing of the runtime
const messagePassingDecoderRegistry = new FinalizationRegistry<MessagePassingRuntime>((runtime) => {
    runtime.unref();
});

// Used when shared memory is not available. Each of the runtime's workers owns an independent decoder, and packets are
// spread across them so multiple can decode in parallel.
class MessagePassingDecoder extends Decoder {
    /** @internal */
    _runtime: MessagePassingRuntime | null;

    constructor(runtime: MessagePassingRuntime) {
        super(true);
        this._runtime = runtime;

        messagePassingDecoderRegistry.register(this, runtime, this);
    }

    protected _runClose() {
        assert(this._runtime);

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
                { type: MessageType.Decode, id, packet, frameBuffer } satisfies WorkerMessage,
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
