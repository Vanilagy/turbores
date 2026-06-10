import { initWasmModule, type WasmExports } from './wasm';

export type Runtime = {
    memory: WebAssembly.Memory;
    exports: WasmExports;
    workers: Worker[];
}

export const canUseSharedMemory = typeof SharedArrayBuffer !== 'undefined';

export const getConcurrency = async (): Promise<number> => {
    if (typeof navigator !== 'undefined' && navigator.hardwareConcurrency) {
        return navigator.hardwareConcurrency;
    }

    // Fallback for server-side environments without `navigator`
    const os = await import('node:os');
    return os.availableParallelism?.() ?? os.cpus().length;
};

let runtimePromise: Promise<Runtime> | null = null;
export const getRuntime = () => runtimePromise ??= initRuntime();

const initRuntime = async (): Promise<Runtime> => {
    const memory = new WebAssembly.Memory({ initial: 32, maximum: 65536, shared: true });
    const exports = await initWasmModule(memory);

    const mainThreadTls = exports.allocateThreadLocalState(exports.__tls_size.value, exports.__tls_align.value);
    if (mainThreadTls === 0) {
        throw new Error('Failed to allocate thread-local state.');
    }
    exports.__wasm_init_tls(mainThreadTls);

    const isBrowserMainThread =
        typeof window !== "undefined" &&
        typeof document !== "undefined" &&
        self === window;
    exports.setIsBrowserMainThread(Number(isBrowserMainThread));

    return { memory, exports, workers: [] };
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
