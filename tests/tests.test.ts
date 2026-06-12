import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { describe, expect, test } from 'vitest';
import {
    Decoder,
    DecoderClosedError,
    Frame,
    FrameLockedError,
    InvalidDataError,
    NotSupportedError,
    UnexpectedEofError,
} from '../src/index.js';

describe('Decoding', () => {
    test('Full HD 422 frame', async () => {
        expect(Decoder.sharedMemoryIsAvailable()).toBe(true);

        const decoder = await Decoder.create({ useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        using frame = new Frame();
        expect(frame.isFilled).toBe(false);
        expect(frame.frameData).toBeNull();

        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        const result = await decoder.decode(packet, frame);

        expect(result).toBe(frame);
        expect(frame.isFilled).toBe(true);
        expect(frame.displayWidth).toBe(1920);
        expect(frame.displayHeight).toBe(1080);
        expect(frame.codedWidth).toBe(1920);
        expect(frame.codedHeight).toBe(1088);
        expect(frame.pixelFormat).toBe('I422P10');
        expect(frame.colorPrimaries).toBe(1);
        expect(frame.colorTransfer).toBe(1);
        expect(frame.colorMatrix).toBe(1);
        expect(frame.colorRangeFull).toBe(false);
        expect(frame.frameData!.byteLength).toBe(1920 * 1088 * 2 * 2);
        const reference = new Uint8Array(gunzipSync(readFileSync(
            new URL('./public/buck-bunny.framedata.gz', import.meta.url),
        )));
        expect(Buffer.compare(frame.frameData!, reference)).toBe(0);

        await decoder.close();

        frame.clear();

        expect(frame.isFilled).toBe(false);
        expect(frame.frameData).toBeNull();
    });

    test('1904-wide frame', async () => {
        const decoder = await Decoder.create({ useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        using frame = new Frame();
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny-1904.prores', import.meta.url)));
        await decoder.decode(packet, frame);

        expect(frame.isFilled).toBe(true);
        expect(frame.displayWidth).toBe(1904);
        expect(frame.displayHeight).toBe(1080);
        expect(frame.codedWidth).toBe(1904);
        expect(frame.codedHeight).toBe(1088);
        expect(frame.pixelFormat).toBe('I422P10');
        expect(frame.frameData!.byteLength).toBe(1904 * 1088 * 2 * 2);
        const reference = new Uint8Array(gunzipSync(readFileSync(
            new URL('./public/buck-bunny-1904.framedata.gz', import.meta.url),
        )));
        expect(Buffer.compare(frame.frameData!, reference)).toBe(0);

        await decoder.close();
    });

    test('444 frame', async () => {
        const decoder = await Decoder.create({ useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        using frame = new Frame();
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny-444.prores', import.meta.url)));
        await decoder.decode(packet, frame);

        expect(frame.isFilled).toBe(true);
        expect(frame.displayWidth).toBe(1904);
        expect(frame.displayHeight).toBe(1080);
        expect(frame.pixelFormat).toBe('I444P10');
        expect(frame.frameData!.byteLength).toBe(1904 * 1088 * 3 * 2);
        const reference = new Uint8Array(gunzipSync(readFileSync(
            new URL('./public/buck-bunny-444.framedata.gz', import.meta.url),
        )));
        expect(Buffer.compare(frame.frameData!, reference)).toBe(0);

        await decoder.close();
    });

    test('Transparent frame', async () => {
        const decoder = await Decoder.create({ useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        using frame = new Frame();
        const packet = new Uint8Array(readFileSync(new URL('./public/transparent-2.prores', import.meta.url)));
        await decoder.decode(packet, frame);

        expect(frame.isFilled).toBe(true);
        expect(frame.displayWidth).toBe(1904);
        expect(frame.displayHeight).toBe(1080);
        expect(frame.pixelFormat).toBe('I444AP10');
        expect(frame.colorPrimaries).toBe(2);
        expect(frame.colorTransfer).toBe(2);
        expect(frame.colorMatrix).toBe(2);
        expect(frame.frameData!.byteLength).toBe(1904 * 1088 * 4 * 2);
        const reference = new Uint8Array(gunzipSync(readFileSync(
            new URL('./public/transparent-2.framedata.gz', import.meta.url),
        )));
        expect(Buffer.compare(frame.frameData!, reference)).toBe(0);

        await decoder.close();
    });
});

describe('Invalid packets', () => {
    test('Frame size larger than packet', async () => {
        const result = await decodeMutated((packet, view) => view.setUint32(0, 0xffffff00));
        expect(result).toBeInstanceOf(InvalidDataError);
        expect((result as Error).message).toMatch(/frame size/);
    });

    test('Invalid frame type', async () => {
        const result = await decodeMutated((packet, view) => view.setUint32(4, 0));
        expect(result).toBeInstanceOf(InvalidDataError);
        expect((result as Error).message).toMatch(/frame type/);
    });

    test('Unsupported version', async () => {
        const result = await decodeMutated((packet, view) => view.setUint16(10, 2));
        expect(result).toBeInstanceOf(NotSupportedError);
        expect((result as Error).message).toMatch(/Version/);
    });

    test('Interlaced frame', async () => {
        const result = await decodeMutated(packet => packet[20]! |= 0b0100);
        expect(result).toBeInstanceOf(NotSupportedError);
        expect((result as Error).message).toMatch(/Interlaced/);
    });

    test('Invalid alpha info', async () => {
        const result = await decodeMutated(packet => packet[25] = (packet[25]! & 0xf0) | 3);
        expect(result).toBeInstanceOf(InvalidDataError);
        expect((result as Error).message).toMatch(/alpha/);
    });

    test('Picture data size larger than packet', async () => {
        const result = await decodeMutated((packet, view) => view.setUint32(picHeaderStart(view) + 1, 0xffffff00));
        expect(result).toBeInstanceOf(InvalidDataError);
        expect((result as Error).message).toMatch(/picture data size/);
    });

    test('Unsupported slice width', async () => {
        const result = await decodeMutated((packet, view) => packet[picHeaderStart(view) + 7] = 0x80);
        expect(result).toBeInstanceOf(NotSupportedError);
        expect((result as Error).message).toMatch(/Slice width/);
    });

    test('Unsupported slice height', async () => {
        const result = await decodeMutated((packet, view) => packet[picHeaderStart(view) + 7]! |= 1);
        expect(result).toBeInstanceOf(NotSupportedError);
        expect((result as Error).message).toMatch(/slice height/);
    });

    test('Unexpected slice count', async () => {
        const result = await decodeMutated((packet, view) => {
            const offset = picHeaderStart(view) + 5;
            view.setUint16(offset, view.getUint16(offset) + 1);
        });
        expect(result).toBeInstanceOf(InvalidDataError);
        expect((result as Error).message).toMatch(/slice count/);
    });

    test('Slice data past picture data bounds', async () => {
        const result = await decodeMutated((packet, view) => {
            const start = picHeaderStart(view);
            const picHeaderSize = packet[start]! >> 3;
            view.setUint16(start + picHeaderSize, 0xffff);
        });
        expect(result).toBeInstanceOf(UnexpectedEofError);
    });

    test('Corrupted slice data', async () => {
        const result = await decodeMutated((packet, view) => {
            const start = picHeaderStart(view);
            const picHeaderSize = packet[start]! >> 3;
            const sliceCount = view.getUint16(start + 5);
            const firstSliceSize = view.getUint16(start + picHeaderSize);
            const firstSliceOffset = start + picHeaderSize + 2 * sliceCount;
            const sliceHeaderSize = packet[firstSliceOffset]! >> 3;
            packet.fill(0, firstSliceOffset + sliceHeaderSize, firstSliceOffset + firstSliceSize);
        });
        expect(result).toBeInstanceOf(InvalidDataError);
        expect((result as Error).message).toMatch(/DC|AC/);
    });
});

describe('Decoding modes', () => {
    test('Shared memory multithreading speedup', async () => {
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        const syncDecoder = await Decoder.create({ useSharedMemory: true, concurrency: 0 });
        if (syncDecoder instanceof Error) {
            throw syncDecoder;
        }
        const threadedDecoder = await Decoder.create({ useSharedMemory: true, concurrency: 4 });
        if (threadedDecoder instanceof Error) {
            throw threadedDecoder;
        }
        using frame = new Frame();
        const iterations = 10;

        await syncDecoder.decode(packet, frame);
        await threadedDecoder.decode(packet, frame); // Warmup

        let start = performance.now();
        for (let i = 0; i < iterations; i++) {
            await syncDecoder.decode(packet, frame);
        }
        const syncTime = performance.now() - start;

        start = performance.now();
        for (let i = 0; i < iterations; i++) {
            await threadedDecoder.decode(packet, frame);
        }
        const threadedTime = performance.now() - start;

        expect(threadedTime).toBeLessThan(syncTime);

        await syncDecoder.close();
        await threadedDecoder.close();
    });

    test('Message passing multithreading speedup', async () => {
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        const decoder = await Decoder.create({ useSharedMemory: false, concurrency: 4 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        const frames = Array.from({ length: 8 }, () => new Frame());

        await Promise.all(frames.map(frame => decoder.decode(packet, frame) as Promise<unknown>)); // Warmup

        let start = performance.now();
        for (const frame of frames) {
            await decoder.decode(packet, frame);
        }
        const serialTime = performance.now() - start;

        start = performance.now();
        await Promise.all(frames.map(frame => decoder.decode(packet, frame) as Promise<unknown>));
        const parallelTime = performance.now() - start;

        expect(parallelTime).toBeLessThan(serialTime);

        await decoder.close();
    });
});

describe('API misuse', () => {
    test('Frame locked during decode', async () => {
        const decoder = await Decoder.create({ useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        using frame = new Frame();

        const promise = decoder.decode(packet, frame);
        expect(frame.isLocked).toBe(true);
        expect(frame.isFilled).toBe(false);
        expect(await decoder.decode(packet, frame)).toBeInstanceOf(FrameLockedError);
        expect(() => frame.clear()).toThrow(FrameLockedError);

        await promise;
        expect(frame.isLocked).toBe(false);
        expect(() => frame.clear()).not.toThrow();

        await decoder.close();
    });

    test('Closed decoder', async () => {
        const decoder = await Decoder.create({ useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        await decoder.close();

        expect(decoder.isClosed).toBe(true);
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        expect(await decoder.decode(packet, new Frame())).toBeInstanceOf(DecoderClosedError);
    });

    test('Serialized results with shared memory', async () => {
        const decoder = await Decoder.create({ useSharedMemory: true, concurrency: 4 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        const packets = [
            new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url))),
            new Uint8Array(readFileSync(new URL('./public/buck-bunny-1904.prores', import.meta.url))),
            new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url))),
            new Uint8Array(readFileSync(new URL('./public/buck-bunny-1904.prores', import.meta.url))),
        ];

        const order: number[] = [];
        const results = await Promise.all(packets.map((packet, i) => {
            const promise = decoder.decode(packet, new Frame()) as Promise<Frame>;
            return promise.then((result) => {
                order.push(i);
                return result;
            });
        }));

        expect(order).toEqual([0, 1, 2, 3]);
        expect(results.map(frame => frame.displayWidth)).toEqual([1920, 1904, 1920, 1904]);

        await decoder.close();
    });

    test('Serialized results with message passing', async () => {
        const decoder = await Decoder.create({ useSharedMemory: false, concurrency: 4 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        const packets = [
            new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url))),
            new Uint8Array(readFileSync(new URL('./public/buck-bunny-1904.prores', import.meta.url))),
            new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url))),
            new Uint8Array(readFileSync(new URL('./public/buck-bunny-1904.prores', import.meta.url))),
        ];

        const order: number[] = [];
        const results = await Promise.all(packets.map((packet, i) => {
            const promise = decoder.decode(packet, new Frame()) as Promise<Frame>;
            return promise.then((result) => {
                order.push(i);
                return result;
            });
        }));

        expect(order).toEqual([0, 1, 2, 3]);
        expect(results.map(frame => frame.displayWidth)).toEqual([1920, 1904, 1920, 1904]);

        await decoder.close();
    });

    test('Packet transfer with shared memory', async () => {
        const decoder = await Decoder.create({ useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        using frame = new Frame();

        const result = await decoder.decode(packet, frame, { transfer: true });
        expect(result).toBe(frame);
        expect(packet.byteLength).toBe(0);

        await decoder.close();
    });

    test('Packet transfer with message passing', async () => {
        const decoder = await Decoder.create({ useSharedMemory: false, concurrency: 1 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        using frame = new Frame();

        const result = await decoder.decode(packet, frame, { transfer: true });
        expect(result).toBe(frame);
        expect(packet.byteLength).toBe(0);

        await decoder.close();
    });

    test('Frame reuse after clear', async () => {
        const decoder = await Decoder.create({ useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        using frame = new Frame();

        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        await decoder.decode(packet, frame);
        frame.clear();
        expect(frame.isFilled).toBe(false);

        const secondPacket = new Uint8Array(readFileSync(new URL('./public/buck-bunny-1904.prores', import.meta.url)));
        await decoder.decode(secondPacket, frame);
        expect(frame.displayWidth).toBe(1904);

        await decoder.close();
    });
});

describe('Input validation', () => {
    test('Create options', async () => {
        // @ts-expect-error Intentionally invalid
        await expect(Decoder.create()).rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(Decoder.create(null)).rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(Decoder.create({})).rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(Decoder.create({ useSharedMemory: 1 })).rejects.toThrow(TypeError);
        await expect(Decoder.create({ useSharedMemory: true, concurrency: -1 })).rejects.toThrow(TypeError);
        await expect(Decoder.create({ useSharedMemory: true, concurrency: 1.5 })).rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(Decoder.create({ useSharedMemory: true, concurrency: '4' })).rejects.toThrow(TypeError);
    });

    test('Decode arguments', async () => {
        const decoder = await Decoder.create({ useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        using frame = new Frame();

        // @ts-expect-error Intentionally invalid
        await expect(() => decoder.decode('packet', frame)).rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(() => decoder.decode(packet, 'frame')).rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(() => decoder.decode(packet, frame, null)).rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(() => decoder.decode(packet, frame, { transfer: 'yes' })).rejects.toThrow(TypeError);

        await decoder.close();
    });
});

const decodeMutated = async (mutate: (packet: Uint8Array, view: DataView) => void) => {
    const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
    mutate(packet, new DataView(packet.buffer));

    const decoder = await Decoder.create({ useSharedMemory: true, concurrency: 0 });
    if (decoder instanceof Error) {
        throw decoder;
    }
    const result = await decoder.decode(packet, new Frame());
    await decoder.close();

    return result;
};

const picHeaderStart = (view: DataView) => 8 + view.getUint16(8);
