import type { Runtime } from './runtime';

export type PixelFormat = `I${'422' | '444'}${'' | 'A'}P${'10' | '12'}`;

export type DecodeResult = {
    frameData: Uint8Array;
    codedWidth: number;
    codedHeight: number;
    displayWidth: number;
    displayHeight: number;
    pixelFormat: PixelFormat;
}

export class Decoder {
    private runtime: Runtime;
    private ptr: number;
    private waitWordAddress: number;

    // All decode and close calls run through this chain, so they never overlap and close waits for in-flight decodes
    private queue: Promise<unknown> = Promise.resolve();

    constructor(runtime: Runtime, ptr: number) {
        this.runtime = runtime;
        this.ptr = ptr;
        this.waitWordAddress = runtime.exports.getWaitWordAddress(ptr);
    }

    decode(packetData: Uint8Array): Promise<DecodeResult | Error> {
        return this.queue.then(() => this.runDecode(packetData));
    }

    close(): Promise<void> {
        return this.queue.then(() => {
            this.runtime.exports.closeDecoder(this.ptr);
        });
    }

    private async runDecode(packetData: Uint8Array): Promise<DecodeResult | Error> {
        const { exports, memory } = this.runtime;

        try {
            const packetPtr = exports.allocatePacket(this.ptr, packetData.byteLength);
            new Uint8Array(memory.buffer).set(packetData, packetPtr);
    
            if (exports.decodePacket(this.ptr) < 0) {
                return new Error('Failed to decode packet');
            }
    
            await Atomics.waitAsync(new Int32Array(memory.buffer), this.waitWordAddress / 4, 0).value;
    
            const codedWidth = exports.getCodedWidth(this.ptr);
            const codedHeight = exports.getCodedHeight(this.ptr);
            const displayWidth = exports.getDisplayWidth(this.ptr);
            const displayHeight = exports.getDisplayHeight(this.ptr);
    
            const frameDataPtr = exports.getFrameDataPtr(this.ptr);
            const frameDataSize = exports.getFrameDataSize(this.ptr);
            const frameData = new Uint8Array(memory.buffer, frameDataPtr, frameDataSize * 2).slice();
    
            const chroma = exports.getChromaSubsampling(this.ptr);
            const alpha = exports.getAlphaBitDepth(this.ptr) !== 0 ? 'A' : '';
            const bitDepth = exports.getBitDepth(this.ptr);
            const pixelFormat = `I${chroma}${alpha}P${bitDepth}` as PixelFormat;
    
            return {
                frameData,
                codedWidth,
                codedHeight,
                displayWidth,
                displayHeight,
                pixelFormat,
            };
        } catch (error) {
            return error as Error;
        }
    }
}
