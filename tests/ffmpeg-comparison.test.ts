// Validates decoded output against ffmpeg — an *independent* decoder. Unlike the .framedata.gz fixtures (which are our
// own past output and so can only catch regressions, not correctness bugs), this catches a genuinely wrong decode
// (e.g. the 12-bit-too-dark bug). ffmpeg can't read our raw ProRes frame fixtures, so we wrap each one in a minimal
// single-frame QuickTime MOV, let ffmpeg decode it to raw planar YUV(A), and compare against our decode plane by plane.
// Skipped automatically when ffmpeg isn't installed.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, test } from 'vitest';
import { Decoder, Frame, type DecoderOptions } from '../src/index.js';

const ffmpegAvailable = (() => {
    try {
        execFileSync('ffmpeg', ['-version'], { stdio: 'ignore' });
        return true;
    } catch {
        return false;
    }
})();

// Minimal single-frame QuickTime MOV muxer — just enough for ffmpeg to find and decode one ProRes frame.
const muxProResMov = (frame: Uint8Array, fourCc: string, width: number, height: number): Buffer => {
    const be32 = (n: number): Buffer => {
        const b = Buffer.alloc(4);
        b.writeUInt32BE(n >>> 0);
        return b;
    };
    const be16 = (n: number): Buffer => {
        const b = Buffer.alloc(2);
        b.writeUInt16BE(n & 0xffff);
        return b;
    };
    const ascii = (s: string) => Buffer.from(s, 'latin1');
    const box = (type: string, ...parts: Buffer[]) => {
        const body = Buffer.concat(parts);
        return Buffer.concat([be32(body.length + 8), ascii(type), body]);
    };
    const matrix = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000].map(be32);

    const ftyp = box('ftyp', ascii('qt  '), be32(0x200), ascii('qt  '));
    const mvhd = box('mvhd', be32(0), be32(0), be32(0), be32(1000), be32(1000), be32(0x00010000), be16(0x0100),
        be16(0), be32(0), be32(0), ...matrix, Buffer.alloc(24), be32(2)); // Buffer.alloc(24) = 6 predefined int32s
    const compressor = Buffer.alloc(32);
    compressor[0] = 6;
    compressor.write('ProRes', 1, 'latin1');
    const sampleEntry = box(fourCc, Buffer.alloc(6), be16(1), Buffer.alloc(16), be16(width), be16(height),
        be32(0x00480000), be32(0x00480000), be32(0), be16(1), compressor, be16(24), be16(0xffff));
    const stsd = box('stsd', be32(0), be32(1), sampleEntry);
    const stts = box('stts', be32(0), be32(1), be32(1), be32(1000));
    const stsc = box('stsc', be32(0), be32(1), be32(1), be32(1), be32(1));
    const stsz = box('stsz', be32(0), be32(frame.length), be32(1));
    const stco = box('stco', be32(0), be32(1), be32(0)); // chunk offset patched below
    const stbl = box('stbl', stsd, stts, stsc, stsz, stco);
    const dinf = box('dinf', box('dref', be32(0), be32(1), box('url ', be32(1))));
    const vmhd = box('vmhd', be32(1), be16(0), be16(0), be16(0), be16(0));
    const minf = box('minf', vmhd, dinf, stbl);
    const hdlr = box('hdlr', be32(0), be32(0), ascii('vide'), be32(0), be32(0), be32(0), ascii('VideoHandler\0'));
    const mdhd = box('mdhd', be32(0), be32(0), be32(0), be32(1000), be32(1000), be16(0x55c4), be16(0));
    const mdia = box('mdia', mdhd, hdlr, minf);
    const tkhd = box('tkhd', be32(0x0007), be32(0), be32(0), be32(1), be32(0), be32(1000), be32(0), be32(0),
        be16(0), be16(0), be16(0), be16(0), ...matrix, be32(width << 16), be32(height << 16));
    const moov = box('moov', mvhd, box('trak', tkhd, mdia));

    const mdatOffset = ftyp.length + moov.length + 8; // 8 = mdat box header
    const stcoValueOffset = moov.indexOf(ascii('stco')) + 4 + 8; // after 'stco' + version/flags + entry count
    moov.writeUInt32BE(mdatOffset, stcoValueOffset);
    return Buffer.concat([ftyp, moov, box('mdat', Buffer.from(frame))]);
};

// turbores pixel format -> ffmpeg pixel format and plane layout ([horizontal, vertical] chroma-subsampling shifts).
const FORMATS: Record<string, { pixFmt: string; planes: [number, number][] }> = {
    I422P10: { pixFmt: 'yuv422p10le', planes: [[0, 0], [1, 0], [1, 0]] },
    I444P10: { pixFmt: 'yuv444p10le', planes: [[0, 0], [0, 0], [0, 0]] },
    I444AP10: { pixFmt: 'yuva444p10le', planes: [[0, 0], [0, 0], [0, 0], [0, 0]] },
    I444AP12: { pixFmt: 'yuva444p12le', planes: [[0, 0], [0, 0], [0, 0], [0, 0]] },
};

// Both are valid ProRes decoders, and ProRes doesn't standardize the inverse DCT, so a few-LSB rounding difference is
// expected (observed: luma ≤4, chroma ≤1, and the run-length-coded alpha bit-exact). A genuine decode bug — wrong
// dequantization, IDCT, or plane layout — diverges by hundreds to thousands, which this comfortably still catches.
const TOLERANCE = 4;

const FIXTURES: { name: string; fourCc: DecoderOptions['proresFourCc'] }[] = [
    { name: 'buck-bunny', fourCc: 'apch' },
    { name: 'buck-bunny-1904', fourCc: 'apch' },
    { name: 'buck-bunny-444', fourCc: 'apch' },
    { name: 'transparent', fourCc: 'apch' },
    { name: '4444-12bit', fourCc: 'ap4h' },
    { name: 'hdr-422', fourCc: 'apch' },
];

describe.skipIf(!ffmpegAvailable)('ffmpeg comparison', () => {
    for (const { name, fourCc } of FIXTURES) {
        test(name, async () => {
            const packet = new Uint8Array(readFileSync(new URL(`./public/${name}.prores`, import.meta.url)));
            const decoder = await Decoder.create({ proresFourCc: fourCc, useSharedMemory: true, concurrency: 0 });
            if (decoder instanceof Error) {
                throw decoder;
            }
            using frame = new Frame();
            const result = await decoder.decode(packet, frame);
            if (result instanceof Error) {
                throw result;
            }
            const layout = FORMATS[result.pixelFormat];
            if (!layout) {
                throw new Error(`no ffmpeg mapping for ${result.pixelFormat}`);
            }

            const dir = mkdtempSync(join(tmpdir(), 'ffcmp-'));
            writeFileSync(join(dir, 'in.mov'), muxProResMov(packet, fourCc, result.visibleWidth, result.visibleHeight));
            execFileSync('ffmpeg', ['-v', 'error', '-i', join(dir, 'in.mov'), '-f', 'rawvideo',
                '-pix_fmt', layout.pixFmt, join(dir, 'out.raw'), '-y']);
            const ffBuf = readFileSync(join(dir, 'out.raw'));

            const { frameData } = result;
            if (!frameData) {
                throw new Error('no frame data');
            }
            const ours = new Uint16Array(frameData.buffer, frameData.byteOffset, frameData.byteLength >> 1);
            const ff = new Uint16Array(ffBuf.buffer, ffBuf.byteOffset, ffBuf.byteLength >> 1);
            const { codedWidth: cw, codedHeight: ch, visibleWidth: vw, visibleHeight: vh } = result;

            let ourOffset = 0;
            let ffOffset = 0;
            let maxDiff = 0;
            for (const [sx, sy] of layout.planes) {
                const codedW = cw >> sx;
                const visW = vw >> sx;
                const visH = vh >> sy;
                for (let y = 0; y < visH; y++) {
                    for (let x = 0; x < visW; x++) {
                        const a = ours[ourOffset + y * codedW + x] ?? 0;
                        const b = ff[ffOffset + y * visW + x] ?? 0;
                        maxDiff = Math.max(maxDiff, Math.abs(a - b));
                    }
                }
                ourOffset += codedW * (ch >> sy);
                ffOffset += visW * visH;
            }
            await decoder.close();

            expect(maxDiff, `${name}: max abs diff vs ffmpeg`).toBeLessThanOrEqual(TOLERANCE);
        });
    }
});
