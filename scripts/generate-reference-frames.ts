// Usage: npx vite-node scripts/generate-reference-frames.ts -- <name> <prores-four-cc> [scale]
// The optional scale (1/2/4/8) decodes downscaled — useful when a full-resolution reference would be too large to
// store (e.g. the 8K fixture, whose full frame is ~280 MB; its reference is generated at 1/8).

import { readFile, writeFile } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';
import { Decoder, Frame, type DecoderOptions } from '../src/index.js';

const [name, proresFourCc, scaleArg] = process.argv.slice(2);
if (!name || !proresFourCc) {
    throw new Error('Usage: generate-reference-frames.ts <name> <prores-four-cc> [scale]');
}

const decoder = await Decoder.create({
    proresFourCc: proresFourCc as DecoderOptions['proresFourCc'],
    useSharedMemory: true,
    concurrency: 0,
    ...(scaleArg ? { scale: Number(scaleArg) as DecoderOptions['scale'] } : {}),
});
if (decoder instanceof Error) {
    throw decoder;
}

const packet = await readFile(new URL(`../tests/public/${name}.prores`, import.meta.url));

const frame = new Frame();
const result = await decoder.decode(new Uint8Array(packet), frame);
if (result instanceof Error) {
    throw result;
}

// Gzip because they big
await writeFile(new URL(`../tests/public/${name}.framedata.gz`, import.meta.url), gzipSync(result.frameData));
console.log(`${name}: ${result.frameData.byteLength} bytes of frame data`);

frame.clear();
await decoder.close();
