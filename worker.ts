import { initWasmModule } from "./wasm-init";

self.addEventListener('message', async (event) => {
    const data = event.data as {
        memory: WebAssembly.Memory;
        stackPointer: number;
        tlsPointer: number;
    };

    const exports = await initWasmModule(data.memory);
    exports.__stack_pointer.value = data.stackPointer;
    exports.__wasm_init_tls(data.tlsPointer);

    exports.setIsWorker(Number(true));

    self.postMessage(null);
    exports.startWorker();
});