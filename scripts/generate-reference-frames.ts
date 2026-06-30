// Usage: npx vite-node scripts/generate-reference-frames.ts -- <name> <prores-four-cc>

import { readFile, writeFile } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';
import { Decoder, Frame, type DecoderOptions } from '../src/index.js';

const [name, proresFourCc] = process.argv.slice(2);
if (!name || !proresFourCc) {
    throw new Error('Usage: generate-reference-frames.ts <name> <prores-four-cc>');
}

const decoder = await Decoder.create({
    proresFourCc: proresFourCc as DecoderOptions['proresFourCc'],
    useSharedMemory: true,
    concurrency: 0,
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
