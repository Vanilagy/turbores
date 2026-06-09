import { initWasmModule, type WasmExports } from './wasm';

export type Runtime = {
    memory: WebAssembly.Memory;
    exports: WasmExports;
    workers: Worker[];
}

let runtimePromise: Promise<Runtime | Error> | null = null;

export const getRuntime = async () => {
    runtimePromise ??= initRuntime();
    const runtime = await runtimePromise;

    // Don't cache a failed init; let the next caller try again
    if (runtime instanceof Error) {
        runtimePromise = null;
    }

    return runtime;
};

const initRuntime = async (): Promise<Runtime | Error> => {
    try {
        const memory = new WebAssembly.Memory({ initial: 32, maximum: 65536, shared: true });
        const exports = await initWasmModule(memory);

        exports.__wasm_init_tls(exports.allocateThreadLocalState(exports.__tls_size.value, exports.__tls_align.value));

        const isBrowserMainThread =
            typeof window !== "undefined" &&
            typeof document !== "undefined" &&
            self === window;
        exports.setIsBrowserMainThread(Number(isBrowserMainThread));

        const concurrency = navigator.hardwareConcurrency;
        const workers: Worker[] = [];
        const ready: Promise<void>[] = [];

        for (let i = 0; i < concurrency; i++) {
            const stackPointer = exports.allocateWorkerStack();
            const tlsPointer = exports.allocateThreadLocalState(exports.__tls_size.value, exports.__tls_align.value);

            const worker = new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' });
            worker.postMessage({ memory, stackPointer, tlsPointer });

            workers.push(worker);
            ready.push(new Promise(resolve => worker.addEventListener('message', () => resolve(), { once: true })));
        }

        await Promise.all(ready);

        return { memory, exports, workers };
    } catch (error) {
        return error instanceof Error ? error : new Error(String(error));
    }
};
