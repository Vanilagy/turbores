import { createErrorFromCodeAndMessage, DecoderClosedError, InvalidDataError, InvalidStateError, NotSupportedError, OutOfMemoryError, UnexpectedEofError } from './errors';
import { decodeUtf8 } from './misc';
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
}

export type DecodeOptions = {
    transfer?: boolean;
};

export abstract class Decoder implements Disposable, AsyncDisposable {
    private _closed = false;
    private queue: Promise<unknown> = Promise.resolve();

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

        const promise = this.queue.then(() => this.runDecode(packetData, options));
        this.queue = promise.catch(() => {});

        return promise;
    }

    close() {
        if (this._closed) {
            // Idempotent: just resolve once whatever is already queued (including the original close) drains.
            return this.queue.then(() => {});
        }
        this._closed = true;

        const promise = this.queue.then(() => this.runClose());
        this.queue = promise.catch(() => {});

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

    protected abstract runDecode(packetData: Uint8Array, options: DecodeOptions): Promise<
        DecodeResult | OutOfMemoryError | UnexpectedEofError | InvalidDataError | NotSupportedError | InvalidStateError
    >;
    protected abstract runClose(): void | Promise<void>;
}

// For automatic freeing of the WASM side
const sharedDecoderRegistry = new FinalizationRegistry<{ runtime: Runtime; ptr: number }>(({ runtime, ptr }) => {
    runtime.exports.closeDecoder(ptr);
});

// Used when proper shared memory is available
class SharedDecoder extends Decoder {
    private runtime: Runtime;
    private ptr: number;
    private waitWordAddress: number;
    // 0 means decodePacket runs synchronously in the main thread
    private concurrency: number;

    constructor(runtime: Runtime, ptr: number, concurrency: number) {
        super();
        this.runtime = runtime;
        this.ptr = ptr;
        this.waitWordAddress = runtime.exports.getWaitWordAddress(ptr);
        this.concurrency = concurrency;

        sharedDecoderRegistry.register(this, { runtime, ptr }, this);
    }

    protected runClose() {
        sharedDecoderRegistry.unregister(this);
        this.runtime.exports.closeDecoder(this.ptr);
    }

    protected async runDecode(packetData: Uint8Array) {
        const { exports, memory } = this.runtime;

        const packetPtr = exports.allocatePacket(this.ptr, packetData.byteLength);
        if (packetPtr === 0) {
            return new OutOfMemoryError();
        }
        new Uint8Array(memory.buffer).set(packetData, packetPtr);

        let resultCode = exports.decodePacket(this.ptr);
        if (resultCode < 0) {
            return this.createError(resultCode);
        }

        if (this.concurrency > 0) {
            // Wait for all workers to finish
            await Atomics.waitAsync(new Int32Array(memory.buffer), this.waitWordAddress / 4, 0).value;

            resultCode = exports.finalizePacketDecoding(this.ptr);
            if (resultCode < 0) {
                return this.createError(resultCode);
            }
        }

        return buildDecodeResult(exports, memory, this.ptr);
    }

    private createError(code: number) {
        const { exports, memory } = this.runtime;

        let errorMessage: string | undefined = undefined;

        const messagePtr = exports.getErrorMessagePtr(this.ptr);
        if (messagePtr !== 0) {
            const size = exports.getErrorMessageSize(this.ptr);
            errorMessage = decodeUtf8(new Uint8Array(memory.buffer, messagePtr, size));
        }

        return createErrorFromCodeAndMessage(code, errorMessage);
    }
}

// Used when shared memory is not available
class StandaloneDecoder extends Decoder {
    private worker: Worker;

    constructor(worker: Worker) {
        super();
        this.worker = worker;
    }

    protected runClose() {
        this.worker.terminate();
    }

    protected runDecode(packetData: Uint8Array, options: DecodeOptions) {
        const packet = options?.transfer ? packetData : packetData.slice();

        return new Promise<
            | DecodeResult | OutOfMemoryError | UnexpectedEofError
            | InvalidDataError | NotSupportedError | InvalidStateError
        >(resolve => {
            this.worker.postMessage(
                { type: 'decode', packet } satisfies WorkerMessage,
                { transfer: [packet.buffer] },
            );

            this.worker.addEventListener('message', (event) => {
                const reply = event.data as WorkerReply;
                if (reply.type === 'decode-error') {
                    resolve(createErrorFromCodeAndMessage(reply.code, reply.message));
                } else if (reply.type === 'decoded') {
                    resolve(reply.result);
                }
            }, { once: true });
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

let warnedAboutMissingHeaders = false;

export type DecoderOptions = {
    threaded?: boolean;
    concurrency?: number;
};

export const createDecoder = async (options: DecoderOptions = {}) => {
    if (typeof options !== 'object' || !options) {
        throw new TypeError('options must be an object.');
    }
    if (options.threaded !== undefined && typeof options.threaded !== 'boolean') {
        throw new TypeError('options.threaded, when provided, must be a boolean.');
    }
    if (options.concurrency !== undefined
        && (!Number.isInteger(options.concurrency) || options.concurrency <= 0)) {
        throw new TypeError('options.concurrency, when provided, must be a positive integer.');
    }

    const threaded = options.threaded ?? true;

    if (threaded && !canUseSharedMemory) {
        // Can't do shared memory, so fall back to a single-worker approach
        if (!warnedAboutMissingHeaders) {
            warnedAboutMissingHeaders = true;
            console.warn(
                'SharedArrayBuffer is unavailable, so decoding falls back to the slow path. '
                + 'For massively increased performance, serve the page cross-origin isolated by setting the '
                + 'Cross-Origin-Opener-Policy: same-origin and Cross-Origin-Embedder-Policy: require-corp headers.',
            );
        }

        const worker = new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' });

        const reply = await new Promise<WorkerReply>(resolve => {
            worker.addEventListener('message', event => resolve(event.data as WorkerReply), { once: true });
            worker.postMessage({ type: 'standalone-init' } satisfies WorkerMessage);
        });

        if (reply.type === 'init-error') {
            worker.terminate();
            return new OutOfMemoryError(reply.message);
        }

        return new StandaloneDecoder(worker);
    }

    const concurrency = threaded
        ? (options.concurrency ?? await getConcurrency())
        : 0; // Also uses the core runtime, just with zero workers which is fine

    const runtime = await getRuntime();
    ensureWorkers(runtime, concurrency);

    const decoderPtr = runtime.exports.createDecoder(concurrency);
    if (decoderPtr === 0) {
        return new OutOfMemoryError();
    }

    return new SharedDecoder(runtime, decoderPtr, concurrency);
};
