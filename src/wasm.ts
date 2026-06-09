export type WasmExports = {
    __stack_pointer: WebAssembly.Global;
    __tls_align: WebAssembly.Global;
    __tls_base: WebAssembly.Global;
    __tls_size: WebAssembly.Global;
    __wasm_init_tls: (ptr: number) => void;

    setIsBrowserMainThread: (value: number) => void;
    allocateWorkerStack: () => number;
    allocateThreadLocalState: (size: number, alignment: number) => number;
    startWorker: () => void;
    getWaitWordAddress: (decoder: number) => number;
    createDecoder: () => number;
    closeDecoder: (decoder: number) => void;
    allocatePacket: (decoder: number, size: number) => number;
    decodePacket: (decoder: number) => number;
    getDisplayWidth: (decoder: number) => number;
    getDisplayHeight: (decoder: number) => number;
    getCodedWidth: (decoder: number) => number;
    getCodedHeight: (decoder: number) => number;
    getFrameDataPtr: (decoder: number) => number;
    getFrameDataSize: (decoder: number) => number;
    getChromaSubsampling: (decoder: number) => number;
    getBitDepth: (decoder: number) => number;
    getAlphaBitDepth: (decoder: number) => number;
};

export const initWasmModule = async (memory: WebAssembly.Memory) => {
    const module = await WebAssembly.instantiateStreaming(fetch(new URL('../build/lib.wasm', import.meta.url)), {
        env: {
            memory,
            externPrint: (offset: number, length: number) => {
                const bytes = new Uint8Array(memory.buffer, offset, length);
                console.log(decodeUtf8(bytes));
            },
        },
    });

    return module.instance.exports as unknown as WasmExports;
};

// This thing is much faster than TextDecoder
// https://gist.github.com/pascaldekloe/62546103a1576803dade9269ccf76330
const decodeUtf8 = (bytes: Uint8Array) => {
    let i = 0, s = '';

    while (i < bytes.length) {
        var c = bytes[i++]!;
        if (c > 127) {
            if (c > 191 && c < 224) {
                if (i >= bytes.length)
                    throw new Error('UTF-8 decode: incomplete 2-byte sequence');
                c = (c & 31) << 6 | bytes[i++]! & 63;
            } else if (c > 223 && c < 240) {
                if (i + 1 >= bytes.length)
                    throw new Error('UTF-8 decode: incomplete 3-byte sequence');
                c = (c & 15) << 12 | (bytes[i++]! & 63) << 6 | bytes[i++]! & 63;
            } else if (c > 239 && c < 248) {
                if (i + 2 >= bytes.length)
                    throw new Error('UTF-8 decode: incomplete 4-byte sequence');
                c = (c & 7) << 18 | (bytes[i++]! & 63) << 12 | (bytes[i++]! & 63) << 6 | bytes[i++]! & 63;
            } else throw new Error('UTF-8 decode: unknown multibyte start 0x' + c.toString(16) + ' at index ' + (i - 1));
        }
        if (c <= 0xffff) s += String.fromCharCode(c);
        else if (c <= 0x10ffff) {
            c -= 0x10000;
            s += String.fromCharCode(c >> 10 | 0xd800);
            s += String.fromCharCode(c & 0x3FF | 0xdc00);
        } else throw new Error('UTF-8 decode: code point 0x' + c.toString(16) + ' exceeds UTF-16 reach');
    }

    return s;
};
