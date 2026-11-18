// Usage: npx tsx scripts/stream-packets-to-stdout.ts <input-file>
//
// Demuxes the file's primary video track and streams it to stdout in a simple binary format:
// 4 bytes ASCII fourcc, then [u32 LE size][data] for every packet in decode order.

import { ALL_FORMATS, EncodedPacketSink, FilePathSource, Input } from 'mediabunny';
import { resolve } from 'node:path';

const [inputFile] = process.argv.slice(2);
if (!inputFile) {
    throw new Error('Usage: stream-packets-to-stdout.ts <input-file>');
}

const input = new Input({
    source: new FilePathSource(resolve(inputFile)),
    formats: ALL_FORMATS,
});

const videoTrack = await input.getPrimaryVideoTrack();
if (!videoTrack) {
    throw new Error('No video track found.');
}
const codec = await videoTrack.getCodec();
if (codec !== 'prores') {
    throw new Error(`Expected a ProRes video track, found '${codec}'.`);
}

const fourCc = await videoTrack.getCodecParameterString();
if (!fourCc || fourCc.length !== 4) {
    throw new Error(`Unexpected codec parameter string: ${fourCc}`);
}

const write = (buffer: Buffer) => new Promise<void>((res) => {
    if (process.stdout.write(buffer)) {
        res();
    } else {
        process.stdout.once('drain', res);
    }
});

await write(Buffer.from(fourCc, 'ascii'));

const sink = new EncodedPacketSink(videoTrack);
for await (const packet of sink.packets()) {
    const sizeBuffer = Buffer.alloc(4);
    sizeBuffer.writeUInt32LE(packet.data.byteLength, 0);
    await write(sizeBuffer);
    await write(Buffer.from(packet.data.buffer, packet.data.byteOffset, packet.data.byteLength));
}
