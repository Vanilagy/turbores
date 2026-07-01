/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import type { Transferable as NodeTransferable, Worker as NodeWorker } from 'node:worker_threads';
import wasmBinaryString from '../build/lib.wasm?inline-binary';
import { OutOfMemoryError } from './errors.js';
import { MessageType, type WorkerMessage, type WorkerReply } from './messages.js';
import { AsyncMutex, identity } from './misc.js';
import { initWasmModule, type WasmExports } from './wasm.js';
import workerSource from './worker?inline-worker';

let wasmBinary: Uint8Array<ArrayBuffer> | null = null;
export const getWasmBinary = () => {
    if (wasmBinary) {
        return wasmBinary;
    }

    // Each character in the string maps 1:1 to a byte
    wasmBinary = new Uint8Array(wasmBinaryString.length);
    for (let i = 0; i < wasmBinaryString.length; i++) {
        wasmBinary[i] = wasmBinaryString.charCodeAt(i);
    }

    return wasmBinary;
};

export const createWorker = async () => {
    // Bun's web Worker is flaky, so don't use Worker for it
    if (typeof Worker !== 'undefined' && !('Bun' in globalThis)) {
        // Browsers and Deno: spin up a module worker straight from the inlined source
        const blob = new Blob([workerSource], { type: 'text/javascript' });
        const url = URL.createObjectURL(blob);
        const worker = new Worker(url, { type: 'module' });

        return new WorkerWrapper(worker, null);
    }

    // Node and Bun: there is no (usable) web Worker, so use worker_threads
    const worker_threads = await import('node:' + identity('worker_threads')) as typeof import('node:worker_threads');
    return new WorkerWrapper(null, new worker_threads.Worker(workerSource, { eval: true }));
};

// Provides a single worker interface over both web workers and node:worker_threads workers
export class WorkerWrapper {
    private wrappedListeners = new Map<(event: { data: unknown }) => void, (data: unknown) => void>();

    constructor(
        private webWorker: Worker | null,
        private nodeWorker: NodeWorker | null,
    ) {}

    postMessage(message: unknown, transferables?: Transferable[]) {
        if (this.webWorker) {
            this.webWorker.postMessage(message, { transfer: transferables ?? [] });
        } else {
            this.nodeWorker!.postMessage(message, (transferables ?? []) as NodeTransferable[]);
        }
    }

    addEventListener(type: 'message', listener: (event: { data: unknown }) => void, options?: { once?: boolean }) {
        if (this.webWorker) {
            this.webWorker.addEventListener(type, listener, options);
        } else {
            const wrapped = (data: unknown) => listener({ data });
            this.wrappedListeners.set(listener, wrapped);

            if (options?.once) {
                this.nodeWorker!.once(type, wrapped);
            } else {
                this.nodeWorker!.on(type, wrapped);
            }
        }
    }

    removeEventListener(type: 'message', listener: (event: { data: unknown }) => void) {
        if (this.webWorker) {
            this.webWorker.removeEventListener(type, listener);
        } else {
            this.nodeWorker!.off(type, this.wrappedListeners.get(listener)!);
            this.wrappedListeners.delete(listener);
        }
    }

    terminate() {
        if (this.webWorker) {
            this.webWorker.terminate();
        } else {
            void this.nodeWorker!.terminate();
        }
    }
}

const runtimeFinalizationRegistry = new FinalizationRegistry((workers: WorkerWrapper[]) => {
    for (const worker of workers) {
        worker.terminate();
    }
});

export const getConcurrency = async (): Promise<number> => {
    if (typeof navigator !== 'undefined' && navigator.hardwareConcurrency) {
        return navigator.hardwareConcurrency;
    }

    // Fallback for server-side environments without `navigator`
    const os = await import('node:' + identity('os')) as typeof import('node:os');
    return os.availableParallelism?.() ?? os.cpus().length;
};

let sharedMemoryRuntimeRef: WeakRef<SharedMemoryRuntime> | null = null;
const getSharedMemoryRuntimeMutex = new AsyncMutex();

export const getSharedMemoryRuntime = async () => {
    const release = await getSharedMemoryRuntimeMutex.acquire();

    try {
        if (sharedMemoryRuntimeRef) {
            const runtime = sharedMemoryRuntimeRef.deref();
            if (runtime) {
                return runtime;
            }
        }

        const runtime = await SharedMemoryRuntime.init();
        sharedMemoryRuntimeRef = new WeakRef(runtime);

        return runtime;
    } finally {
        release();
    }
};

let messagePassingRuntimeRef: WeakRef<MessagePassingRuntime> | null = null;

export const getMessagePassingRuntime = () => {
    let runtime = messagePassingRuntimeRef?.deref();
    if (!runtime) {
        runtime = new MessagePassingRuntime();
        messagePassingRuntimeRef = new WeakRef(runtime);
    }

    return runtime;
};

abstract class Runtime {
    workers: WorkerWrapper[] = [];
    // The number of decoders currently using this runtime
    refCount = 0;

    constructor() {
        runtimeFinalizationRegistry.register(this, this.workers, this);
    }

    ref() {
        this.refCount++;
    }

    unref() {
        this.refCount--;

        // In browsers, idle workers don't block anything, so we leave the runtime around and let GC clean it up lazily.
        // Everywhere else (Node, Bun, Deno), alive workers keep the process from exiting, so destroy the runtime as
        // soon as it loses its last decoder.
        const isBrowser = typeof window !== 'undefined' && typeof document !== 'undefined';
        if (!isBrowser && this.refCount === 0) {
            this.destroy();
        }
    }

    protected destroy() {
        for (const worker of this.workers) {
            worker.terminate();
        }
        this.workers.length = 0;

        runtimeFinalizationRegistry.unregister(this);
    }
}

export class SharedMemoryRuntime extends Runtime {
    constructor(
        public memory: WebAssembly.Memory,
        public exports: WasmExports,
    ) {
        super();
    }

    static async init() {
        const memory = new WebAssembly.Memory({ initial: 32, maximum: 65536, shared: true });
        const exports = await initWasmModule(getWasmBinary(), memory);

        const mainThreadTls = exports.allocateThreadLocalState(exports.__tls_size.value, exports.__tls_align.value);
        if (mainThreadTls === 0) {
            throw new Error('Failed to allocate thread-local state.');
        }
        exports.__wasm_init_tls(mainThreadTls);

        const isBrowserMainThread
            = typeof window !== 'undefined'
                && typeof document !== 'undefined'
                && self === window;
        exports.setIsBrowserMainThread(Number(isBrowserMainThread));

        return new SharedMemoryRuntime(memory, exports);
    }

    async ensureWorkers(count: number) {
        // Add however many workers are missing
        while (this.workers.length < count) {
            const stackPointer = this.exports.allocateWorkerStack();
            const tlsPointer = this.exports.allocateThreadLocalState(
                this.exports.__tls_size.value,
                this.exports.__tls_align.value,
            );
            if (stackPointer === 0 || tlsPointer === 0) {
                throw new Error('Failed to allocate worker stack or thread-local state.');
            }

            const worker = await createWorker();
            worker.postMessage({
                type: MessageType.SharedMemoryInit,
                wasmBinary: getWasmBinary(),
                memory: this.memory,
                stackPointer,
                tlsPointer,
            } satisfies WorkerMessage);

            this.workers.push(worker);
        }
    }

    protected override destroy() {
        super.destroy();

        // Make sure the next decoder gets a fresh runtime
        sharedMemoryRuntimeRef = null;
    }
}

export class MessagePassingRuntime extends Runtime {
    // How many packets each worker currently has in flight
    workerLoad: number[] = [];
    nextRequestId = 0;
    nextDecoderId = 0;
    registeredDecoders = new Map<number, {
        bitDepth: number;
        allowedOutputFormats: number;
    }>();

    registerDecoder(decoderId: number, bitDepth: number, allowedOutputFormats: number) {
        this.registeredDecoders.set(decoderId, { bitDepth, allowedOutputFormats });

        for (const worker of this.workers) {
            worker.postMessage({
                type: MessageType.CreateDecoder,
                decoderId,
                bitDepth,
                allowedOutputFormats,
            } satisfies WorkerMessage);
        }
    }

    unregisterDecoder(decoderId: number) {
        this.registeredDecoders.delete(decoderId);

        for (const worker of this.workers) {
            worker.postMessage({
                type: MessageType.CloseDecoder,
                decoderId,
            } satisfies WorkerMessage);
        }
    }

    async ensureWorkers(count: number) {
        const missing = count - this.workers.length;
        if (missing <= 0) {
            return;
        }

        const results = await Promise.all(
            Array.from({ length: missing }, async () => {
                const worker = await createWorker();

                const reply = await new Promise<WorkerReply>((resolve) => {
                    worker.postMessage({
                        type: MessageType.MessagePassingInit,
                        wasmBinary: getWasmBinary(),
                    } satisfies WorkerMessage);
                    worker.addEventListener('message', event => resolve(event.data as WorkerReply), { once: true });
                });

                if (reply.type === MessageType.InitOutOfMemoryError) {
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

        for (const worker of results as WorkerWrapper[]) {
            this.workers.push(worker);
            this.workerLoad.push(0);

            // Bring the fresh worker up to speed with every decoder that already exists
            for (const [decoderId, { bitDepth, allowedOutputFormats }] of this.registeredDecoders) {
                worker.postMessage({
                    type: MessageType.CreateDecoder,
                    decoderId,
                    bitDepth,
                    allowedOutputFormats,
                } satisfies WorkerMessage);
            }
        }
    }

    protected override destroy() {
        super.destroy();

        // Make sure the next decoder gets a fresh runtime
        messagePassingRuntimeRef = null;
    }
}
