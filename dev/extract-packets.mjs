/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Extracts every ProRes video packet from a file using Mediabunny and streams them to stdout in a simple binary
 * framing, so the native C benchmarks can consume them without an FFmpeg/libavformat dependency.
 *
 * Usage:  node dev/extract-packets.mjs <video-file>
 *
 * Output framing (little-endian) on stdout:
 *   "TRP1"            4-byte magic
 *   uint32 bitDepth   10 or 12
 *   uint32 width      display width
 *   uint32 height     display height
 *   then, repeated until EOF, one record per packet:
 *     uint32 size
 *     <size> bytes of packet data
 */

import { ALL_FORMATS, EncodedPacketSink, FilePathSource, Input } from 'mediabunny';

const path = process.argv[2];
if (!path) {
    process.stderr.write('Usage: extract-packets.mjs <video-file>\n');
    process.exit(2);
}

// Await-able write that respects backpressure and guarantees the buffer is safe to reuse afterwards.
const write = (buf) => new Promise((resolve, reject) => {
    process.stdout.write(buf, (err) => (err ? reject(err) : resolve()));
});

const input = new Input({
    source: new FilePathSource(path),
    formats: ALL_FORMATS,
});

const videoTrack = await input.getPrimaryVideoTrack();
if (!videoTrack) {
    process.stderr.write('The file has no video track.\n');
    process.exit(1);
}

// For ISOBMFF files, internalCodecId is the sample entry name, i.e. the ProRes FourCC.
const fourCc = videoTrack.internalCodecId;
if (typeof fourCc !== 'string') {
    process.stderr.write(`Unexpected codec id (not a ProRes FourCC string): ${String(fourCc)}\n`);
    process.exit(1);
}
// ProRes 4444 / 4444 XQ are 12-bit; all other profiles are 10-bit.
const bitDepth = (fourCc === 'ap4h' || fourCc === 'ap4x') ? 12 : 10;

const header = Buffer.alloc(16);
header.write('TRP1', 0, 'ascii');
header.writeUInt32LE(bitDepth, 4);
header.writeUInt32LE(videoTrack.displayWidth, 8);
header.writeUInt32LE(videoTrack.displayHeight, 12);
await write(header);

const sink = new EncodedPacketSink(videoTrack);
const sizeBuf = Buffer.alloc(4);
for await (const packet of sink.packets()) {
    const data = packet.data;
    sizeBuf.writeUInt32LE(data.byteLength, 0);
    await write(sizeBuf);
    await write(Buffer.from(data.buffer, data.byteOffset, data.byteLength));
}
