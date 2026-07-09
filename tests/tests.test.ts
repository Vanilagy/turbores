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
    PIXEL_FORMATS,
    type PixelFormat,
    UnexpectedEofError,
} from '../src/index.js';

describe('Decoding', () => {
    test('Full HD 422 frame', async () => {
        expect(Decoder.canUseSharedMemory()).toBe(true);

        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
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
        expect(frame.visibleWidth).toBe(1920);
        expect(frame.visibleHeight).toBe(1080);
        expect(frame.codedWidth).toBe(1920);
        expect(frame.codedHeight).toBe(1088);
        expect(frame.pixelAspectRatio).toEqual({ num: 1, den: 1 });
        expect(frame.pixelFormat).toBe('I422P10');
        expect(frame.originalPixelFormat).toBe('I422P10');
        expect(frame.colorPrimaries).toBe(1);
        expect(frame.colorTransfer).toBe(1);
        expect(frame.colorMatrix).toBe(1);
        expect(frame.colorRangeFull).toBe(false);
        expect(frame.scanType).toBe('progressive');
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
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        using frame = new Frame();
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny-1904.prores', import.meta.url)));
        await decoder.decode(packet, frame);

        expect(frame.isFilled).toBe(true);
        expect(frame.visibleWidth).toBe(1904);
        expect(frame.visibleHeight).toBe(1080);
        expect(frame.codedWidth).toBe(1904);
        expect(frame.codedHeight).toBe(1088);
        expect(frame.pixelFormat).toBe('I422P10');
        expect(frame.scanType).toBe('progressive');
        expect(frame.frameData!.byteLength).toBe(1904 * 1088 * 2 * 2);
        const reference = new Uint8Array(gunzipSync(readFileSync(
            new URL('./public/buck-bunny-1904.framedata.gz', import.meta.url),
        )));
        expect(Buffer.compare(frame.frameData!, reference)).toBe(0);

        await decoder.close();
    });

    test('444 frame', async () => {
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        using frame = new Frame();
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny-444.prores', import.meta.url)));
        await decoder.decode(packet, frame);

        expect(frame.isFilled).toBe(true);
        expect(frame.visibleWidth).toBe(1904);
        expect(frame.visibleHeight).toBe(1080);
        expect(frame.pixelFormat).toBe('I444P10');
        expect(frame.scanType).toBe('progressive');
        expect(frame.frameData!.byteLength).toBe(1904 * 1088 * 3 * 2);
        const reference = new Uint8Array(gunzipSync(readFileSync(
            new URL('./public/buck-bunny-444.framedata.gz', import.meta.url),
        )));
        expect(Buffer.compare(frame.frameData!, reference)).toBe(0);

        await decoder.close();
    });

    test('Transparent frame', async () => {
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        using frame = new Frame();
        const packet = new Uint8Array(readFileSync(new URL('./public/transparent.prores', import.meta.url)));
        await decoder.decode(packet, frame);

        expect(frame.isFilled).toBe(true);
        expect(frame.visibleWidth).toBe(1904);
        expect(frame.visibleHeight).toBe(1080);
        expect(frame.pixelFormat).toBe('I444AP10');
        expect(frame.colorPrimaries).toBe(2);
        expect(frame.colorTransfer).toBe(2);
        expect(frame.colorMatrix).toBe(2);
        expect(frame.scanType).toBe('progressive');
        expect(frame.frameData!.byteLength).toBe(1904 * 1088 * 4 * 2);
        const reference = new Uint8Array(gunzipSync(readFileSync(
            new URL('./public/transparent.framedata.gz', import.meta.url),
        )));
        expect(Buffer.compare(frame.frameData!, reference)).toBe(0);

        await decoder.close();
    });

    test('12-bit transparent frame', async () => {
        const decoder = await Decoder.create({ proresFourCc: 'ap4h', useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        using frame = new Frame();
        const packet = new Uint8Array(readFileSync(new URL('./public/4444-12bit.prores', import.meta.url)));
        await decoder.decode(packet, frame);

        expect(frame.isFilled).toBe(true);
        expect(frame.visibleWidth).toBe(1920);
        expect(frame.visibleHeight).toBe(1080);
        expect(frame.pixelFormat).toBe('I444AP12');
        expect(frame.scanType).toBe('progressive');
        expect(frame.frameData!.byteLength).toBe(1920 * 1088 * 4 * 2);

        // The frame is black, so luma must sit at video-range black and chroma at the neutral midpoint, at proper
        // 12-bit scale. This guards against values coming out at the wrong scale (as the coefficient scale of the
        // bitstream is the same for all ProRes variants).
        const view = new DataView(frame.frameData!.buffer, frame.frameData!.byteOffset);
        expect(view.getUint16(0, true)).toBe(16 << 4); // Y
        expect(view.getUint16(1920 * 1088 * 2, true)).toBe(128 << 4); // U

        const reference = new Uint8Array(gunzipSync(readFileSync(
            new URL('./public/4444-12bit.framedata.gz', import.meta.url),
        )));
        expect(Buffer.compare(frame.frameData!, reference)).toBe(0);

        await decoder.close();
    });

    test('Interlaced frame', async () => {
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        using frame = new Frame();
        const packet = new Uint8Array(readFileSync(new URL('./public/interlaced-buck-bunny.prores', import.meta.url)));
        await decoder.decode(packet, frame);

        expect(frame.isFilled).toBe(true);
        expect(frame.visibleWidth).toBe(1920);
        expect(frame.visibleHeight).toBe(1080);
        expect(frame.codedWidth).toBe(1920);
        expect(frame.codedHeight).toBe(1088);
        expect(frame.pixelFormat).toBe('I422P10');
        expect(frame.scanType).toBe('interlaced-top-field-first');
        expect(frame.frameData!.byteLength).toBe(1920 * 1088 * 2 * 2);
        const reference = new Uint8Array(gunzipSync(readFileSync(
            new URL('./public/interlaced-buck-bunny.framedata.gz', import.meta.url),
        )));
        expect(Buffer.compare(frame.frameData!, reference)).toBe(0);

        await decoder.close();
    });

    test('HDR 422 frame', async () => {
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        using frame = new Frame();
        const packet = new Uint8Array(readFileSync(new URL('./public/hdr-422.prores', import.meta.url)));
        await decoder.decode(packet, frame);

        expect(frame.isFilled).toBe(true);
        expect(frame.visibleWidth).toBe(1920);
        expect(frame.visibleHeight).toBe(1080);
        expect(frame.codedWidth).toBe(1920);
        expect(frame.codedHeight).toBe(1088);
        expect(frame.pixelAspectRatio).toEqual({ num: 1, den: 1 });
        expect(frame.pixelFormat).toBe('I422P10');
        expect(frame.colorPrimaries).toBe(9);
        expect(frame.colorTransfer).toBe(18);
        expect(frame.colorMatrix).toBe(9);
        expect(frame.scanType).toBe('progressive');
        expect(frame.frameData!.byteLength).toBe(1920 * 1088 * 2 * 2);
        const reference = new Uint8Array(gunzipSync(readFileSync(
            new URL('./public/hdr-422.framedata.gz', import.meta.url),
        )));
        expect(Buffer.compare(frame.frameData!, reference)).toBe(0);

        await decoder.close();
    });
});

describe('Invalid packets', () => {
    const decodeMutated = async (mutate: (packet: Uint8Array, view: DataView) => void) => {
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        mutate(packet, new DataView(packet.buffer));

        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        const result = await decoder.decode(packet, new Frame());
        await decoder.close();

        return result;
    };

    const picHeaderStart = (view: DataView) => 8 + view.getUint16(8);

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

    test('Invalid scan type', async () => {
        const result = await decodeMutated(packet => packet[20]! |= 0b1100);
        expect(result).toBeInstanceOf(InvalidDataError);
        expect((result as Error).message).toMatch(/frame type/);
    });

    test('Invalid alpha info', async () => {
        const result = await decodeMutated(packet => packet[25] = (packet[25]! & 0xf0) | 3);
        expect(result).toBeInstanceOf(InvalidDataError);
        expect((result as Error).message).toMatch(/alpha/);
    });

    test('Invalid aspect ratio information', async () => {
        const result = await decodeMutated(packet => packet[21] = (packet[21]! & 0x0f) | 0x40);
        expect(result).toBeInstanceOf(InvalidDataError);
        expect((result as Error).message).toMatch(/aspect ratio/);
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
    const reference = new Uint8Array(gunzipSync(readFileSync(
        new URL('./public/buck-bunny.framedata.gz', import.meta.url),
    )));

    test('Shared memory multithreading speedup', async () => {
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        const syncDecoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
        if (syncDecoder instanceof Error) {
            throw syncDecoder;
        }
        const threadedDecoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 4 });
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

        expect(Buffer.compare(frame.frameData!, reference)).toBe(0);

        start = performance.now();
        for (let i = 0; i < iterations; i++) {
            await threadedDecoder.decode(packet, frame);
        }
        const threadedTime = performance.now() - start;

        expect(threadedTime).toBeLessThan(syncTime);

        // The threaded decode must produce the exact same result as a single-threaded one
        expect(Buffer.compare(frame.frameData!, reference)).toBe(0);

        await syncDecoder.close();
        await threadedDecoder.close();
    });

    test('Message passing multithreading speedup', async () => {
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: false, concurrency: 4 });
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

        // Every worker must have produced the exact same correct result
        for (const frame of frames) {
            expect(Buffer.compare(frame.frameData!, reference)).toBe(0);
        }

        await decoder.close();
    });
});

describe('API misuse', () => {
    test('Frame locked during decode', async () => {
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
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
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
        if (decoder instanceof Error) {
            throw decoder;
        }
        await decoder.close();

        expect(decoder.isClosed).toBe(true);
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));
        expect(await decoder.decode(packet, new Frame())).toBeInstanceOf(DecoderClosedError);
    });

    test('Serialized results with shared memory', async () => {
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 4 });
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
        expect(results.map(frame => frame.visibleWidth)).toEqual([1920, 1904, 1920, 1904]);

        await decoder.close();
    });

    test('Serialized results with message passing', async () => {
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: false, concurrency: 4 });
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
        expect(results.map(frame => frame.visibleWidth)).toEqual([1920, 1904, 1920, 1904]);

        await decoder.close();
    });

    test('Packet transfer with shared memory', async () => {
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
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
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: false, concurrency: 1 });
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
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
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
        expect(frame.visibleWidth).toBe(1904);

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
        await expect(Decoder.create({ proresFourCc: 'apch' })).rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(Decoder.create({ useSharedMemory: true })).rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(Decoder.create({ proresFourCc: 'xxxx', useSharedMemory: true })).rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(Decoder.create({ proresFourCc: 42, useSharedMemory: true })).rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(Decoder.create({ proresFourCc: 'apch', useSharedMemory: 1 })).rejects.toThrow(TypeError);
        await expect(Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: -1 }))
            .rejects.toThrow(TypeError);
        await expect(Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 1.5 }))
            .rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: '4' }))
            .rejects.toThrow(TypeError);
        await expect(Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, allowedOutputFormats: [] }))
            .rejects.toThrow(TypeError);
        // @ts-expect-error Intentionally invalid
        await expect(Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, allowedOutputFormats: 'I422P10' }))
            .rejects.toThrow(TypeError);
        await expect(Decoder.create({
            proresFourCc: 'apch',
            useSharedMemory: true,
            // @ts-expect-error Intentionally invalid
            allowedOutputFormats: ['I422P10', 'NOPE'],
        })).rejects.toThrow(TypeError);
    });

    test('Decode arguments', async () => {
        const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
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

describe('Multiple decoders', () => {
    test('Shared memory', async () => {
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));

        // A synchronous and a multithreaded decoder sharing the same runtime, decoding into the same frame over many
        // iterations. This path previously corrupted memory due to a stack oopsie.
        const a = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 0 });
        const b = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true, concurrency: 4 });
        if (a instanceof Error) {
            throw a;
        }
        if (b instanceof Error) {
            throw b;
        }
        using frame = new Frame();

        for (let i = 0; i < 5; i++) {
            await a.decode(packet, frame);
            expect(frame.visibleWidth).toBe(1920);
            expect(frame.pixelFormat).toBe('I422P10');

            await b.decode(packet, frame);
            expect(frame.visibleWidth).toBe(1920);
            expect(frame.pixelFormat).toBe('I422P10');
        }

        await a.close();
        await b.close();
    });

    test('Message passing', async () => {
        const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));

        // Two decoders sharing the message-passing worker pool, each with a different output format. Each
        // worker must hold a distinct WASM decoder per main-thread decoder for this to come out right.
        const a = await Decoder.create({
            proresFourCc: 'apch',
            useSharedMemory: false,
            concurrency: 2,
            allowedOutputFormats: ['I422P10'],
        });
        const b = await Decoder.create({
            proresFourCc: 'apch',
            useSharedMemory: false,
            concurrency: 2,
            allowedOutputFormats: ['I420'],
        });
        if (a instanceof Error) {
            throw a;
        }
        if (b instanceof Error) {
            throw b;
        }
        using frameA = new Frame();
        using frameB = new Frame();

        await Promise.all([a.decode(packet, frameA), b.decode(packet, frameB)]);

        expect(frameA.pixelFormat).toBe('I422P10');
        expect(frameB.pixelFormat).toBe('I420');
        expect(frameA.visibleWidth).toBe(1920);
        expect(frameB.visibleWidth).toBe(1920);

        await a.close();
        await b.close();
    });
});

describe('Pixel format conversion', () => {
    const expectedFrameByteLength = (format: PixelFormat, codedWidth: number, codedHeight: number) => {
        const luma = codedWidth * codedHeight;
        const chromaSubsampling = format.slice(0, 4); // 'I420', 'I422' or 'I444'
        const chroma = chromaSubsampling === 'I420' ? luma / 2 : chromaSubsampling === 'I422' ? luma : 2 * luma;
        const alpha = format[4] === 'A' ? luma : 0;
        const bytesPerSample = format.endsWith('10') || format.endsWith('12') ? 2 : 1;

        return (luma + chroma + alpha) * bytesPerSample;
    };

    const sources = [
        { name: '422 frame', fourCc: 'apch', file: 'buck-bunny.prores', format: 'I422P10' },
        { name: '444 frame', fourCc: 'apch', file: 'buck-bunny-444.prores', format: 'I444P10' },
        { name: 'transparent frame', fourCc: 'apch', file: 'transparent.prores', format: 'I444AP10' },
        { name: '12-bit transparent frame', fourCc: 'ap4h', file: '4444-12bit.prores', format: 'I444AP12' },
    ] as const;

    for (const source of sources) {
        for (const target of PIXEL_FORMATS) {
            test(`${source.name} -> ${target}`, async () => {
                const decoder = await Decoder.create({
                    proresFourCc: source.fourCc,
                    useSharedMemory: true,
                    concurrency: 0,
                    allowedOutputFormats: [target],
                });
                if (decoder instanceof Error) {
                    throw decoder;
                }
                using frame = new Frame();
                const packet = new Uint8Array(readFileSync(new URL(`./public/${source.file}`, import.meta.url)));

                const result = await decoder.decode(packet, frame);
                expect(result).toBe(frame);
                expect(frame.isFilled).toBe(true);
                expect(frame.pixelFormat).toBe(target);
                expect(frame.originalPixelFormat).toBe(source.format);
                expect(frame.frameData!.byteLength).toBe(
                    expectedFrameByteLength(target, frame.codedWidth!, frame.codedHeight!),
                );

                await decoder.close();
            });
        }
    }
});

describe('Pixel format preference', () => {
    // The source frame is I422P10. The array below is the decoder's exact order of preference: each entry
    // is what it should fall back to once everything before it is unavailable. Each test slices one more
    // format off the front (removing the previously-selected one) and asserts the choice changes accordingly.
    const preferenceOrder: { format: PixelFormat; reason: string }[] = [
        { format: 'I422P10', reason: 'picks the actual format when available' },
        { format: 'I422P12', reason: 'prefers higher bit depth over higher chroma' },
        { format: 'I444P10', reason: 'prefers higher chroma once bit depth cannot improve losslessly' },
        { format: 'I422AP10', reason: 'adds an alpha plane when chroma and bit depth are preserved' },
        { format: 'I420P12', reason: 'with no lossless option left, takes higher bit depth at lower chroma' },
        { format: 'I420P10', reason: 'prefers lower chroma at the same bit depth' },
        { format: 'I422', reason: 'prefers lower bit depth at the same chroma' },
        { format: 'I420', reason: 'steps down both chroma and bit depth' },
        {
            format: 'I420A',
            reason: 'steps down both chroma and bit depth and even adds unnecessary alpha channel, '
                + 'landing at the worst format',
        },
    ];

    for (let i = 0; i < preferenceOrder.length; i++) {
        const { format, reason } = preferenceOrder[i]!;

        test(`${i + 1}. ${reason}`, async () => {
            const allowedOutputFormats = preferenceOrder.slice(i).map(entry => entry.format);
            const decoder = await Decoder.create({
                proresFourCc: 'apch',
                useSharedMemory: true,
                concurrency: 0,
                allowedOutputFormats,
            });
            if (decoder instanceof Error) {
                throw decoder;
            }
            using frame = new Frame();
            const packet = new Uint8Array(readFileSync(new URL('./public/buck-bunny.prores', import.meta.url)));

            await decoder.decode(packet, frame);
            expect(frame.pixelFormat).toBe(format);

            await decoder.close();
        });
    }
});
