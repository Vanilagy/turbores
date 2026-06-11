/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { AsyncMutex } from './misc';
import { initWasmModule, type WasmExports } from './wasm';

export type Runtime = {
    memory: WebAssembly.Memory;
    exports: WasmExports;
    workers: Worker[];
};

const runtimeFinalizationRegistry = new FinalizationRegistry((workers: Worker[]) => {
    for (const worker of workers) {
        worker.terminate();
    }
});

export const canUseSharedMemory = typeof SharedArrayBuffer !== 'undefined';

export const getConcurrency = async (): Promise<number> => {
    if (typeof navigator !== 'undefined' && navigator.hardwareConcurrency) {
        return navigator.hardwareConcurrency;
    }

    // Fallback for server-side environments without `navigator`
    const os = await import('node:os');
    return os.availableParallelism?.() ?? os.cpus().length;
};

let runtimeRef: WeakRef<Runtime> | null = null;
const getRuntimeMutex = new AsyncMutex();

export const getRuntime = async () => {
    const release = await getRuntimeMutex.acquire();

    try {
        if (runtimeRef) {
            const runtime = runtimeRef.deref();
            if (runtime) {
                return runtime;
            }
        }

        const runtime = await initRuntime();
        runtimeRef = new WeakRef(runtime);

        return runtime;
    } finally {
        release();
    }
};

const initRuntime = async () => {
    const memory = new WebAssembly.Memory({ initial: 32, maximum: 65536, shared: true });
    const exports = await initWasmModule(memory);

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

    const result: Runtime = { memory, exports, workers: [] };
    runtimeFinalizationRegistry.register(result, result.workers);

    return result;
};

export const ensureWorkers = (runtime: Runtime, count: number) => {
    const { memory, exports, workers } = runtime;

    // Add however many workers are missing
    while (workers.length < count) {
        const stackPointer = exports.allocateWorkerStack();
        const tlsPointer = exports.allocateThreadLocalState(exports.__tls_size.value, exports.__tls_align.value);
        if (stackPointer === 0 || tlsPointer === 0) {
            throw new Error('Failed to allocate worker stack or thread-local state.');
        }

        const worker = new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' });
        worker.postMessage({ type: 'shared-worker', memory, stackPointer, tlsPointer });

        workers.push(worker);
    }
};
