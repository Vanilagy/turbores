import { ALL_FORMATS, EncodedPacketSink, FilePathSource, Input } from 'mediabunny';

const input = new Input({
    source: new FilePathSource('/Users/david/Downloads/IMG_0159-prores-hdr.MOV'),
    formats: ALL_FORMATS,
});

const videoTrack = (await input.getPrimaryVideoTrack())!;
const sink = new EncodedPacketSink(videoTrack);
const packet = (await sink.getFirstPacket())!;

const packetData = packet.data;
const dataView = new DataView(packetData.buffer, packetData.byteOffset, packetData.byteLength);

let pos = 0;

// Frame container atom
const frameSize = dataView.getUint32(pos); pos += 4;
const frameTypeOuter = dataView.getUint32(pos); pos += 4;

// Frame header
const hdrSize = dataView.getUint16(pos); pos += 2;
const version = dataView.getUint16(pos); pos += 2;
const creatorId = dataView.getUint32(pos); pos += 4;
const frameWidth = dataView.getUint16(pos); pos += 2;
const frameHeight = dataView.getUint16(pos); pos += 2;
const frameFlags = dataView.getUint8(pos); pos += 1;
const chrominanceFactor = frameFlags >> 6;
const frameType = (frameFlags >> 2) & 0b11;
pos += 1; // reserved1
const primaries = dataView.getUint8(pos); pos += 1;
const transferFunction = dataView.getUint8(pos); pos += 1;
const colorMatrix = dataView.getUint8(pos); pos += 1;
const nextByte = dataView.getUint8(pos); pos += 1;
const srcPixFormat = nextByte >> 4;
const alphaInfo = nextByte & 0b1111;
pos += 1; // reserved2
const qMatFlags = dataView.getUint8(pos); pos += 1;
let qMatLuma: Uint8Array | null = null;
let qMatChroma: Uint8Array | null = null;

if (qMatFlags & 0b10) {
    qMatLuma = packetData.subarray(pos, pos + 64);
    pos += 64;
}
if (qMatFlags & 0b01) {
    qMatChroma = packetData.subarray(pos, pos + 64);
    pos += 64;
}

console.log(hdrSize, version, creatorId, frameWidth, frameHeight, chrominanceFactor, frameType, primaries, transferFunction, colorMatrix, srcPixFormat, alphaInfo, qMatFlags, qMatLuma, qMatChroma);

// Picture header
const picHdrSize = dataView.getUint8(pos); pos += 1;
const picDataSize = dataView.getUint32(pos); pos += 4;
const totalSlices = dataView.getUint16(pos); pos += 2;
const sliceDimensions = dataView.getUint8(pos); pos += 1;
const sliceWidth = 1 << (sliceDimensions >> 4);
const sliceHeight = 1 << (sliceDimensions & 0b1111);

const sliceSizes = new Uint16Array(totalSlices);
for (let i = 0; i < totalSlices; i++) {
    sliceSizes[i] = dataView.getUint16(pos); pos += 2;
}

for (let i = 0; i < totalSlices; i++) {
    const startPos = pos;
    const sliceHdrSize = dataView.getUint8(pos); pos += 1;
    const scaleFactor = dataView.getUint8(pos); pos += 1;
    const lumaDataSize = dataView.getUint16(pos); pos += 2;
    const uDataSize = dataView.getUint16(pos); pos += 2;
    
    console.log(sliceHdrSize, scaleFactor, lumaDataSize, uDataSize);

    let bitPos = 8 * pos;

    const getBit = () => {
        const byte = Math.floor(bitPos / 8);
        const bit = 7 - (bitPos % 8);
        bitPos++;
        return (packetData[byte]! >> bit) & 0b1;
    };

    const getBits = (n: number) => {
        let res = 0;

        for (let i = 0; i < n; i++) {
            res = (res << 1) | getBit();
        }

        return res;
    };

    const getUnary = () => {
        let res = 0;
        while (getBit()) {
            res++;
        }

        return res;
    };

    const getCode = (params: number) => {
        const mp = params & 0b11;
        const g = (params >> 2) & 0b111;
        const r = params >> 5;

        const n = getUnary();
        if (n > mp) {
            return getBits(g + (n - mp - 1)) + ((mp + 1) << r);
        } else if (r > 0) {
            return (1 << n) | getBits(r);
        } else {
            return n;
        }
    };

    const numDcs = sliceWidth * sliceHeight * 4; // 4 luma blocks per macroblock
    const dcCodeParams = [0x04, 0x28, 0x28, 0x4D, 0x4D, 0x70, 0x70];
    let code = getCode(0xB8);

    const dc = new Int32Array(numDcs);
    dc[0] = (code >> 1) ^ -(code & 1);

    code = 5;
    let sign = 0;
    for (let i = 1; i < numDcs; i++) {
        code = getCode(dcCodeParams[Math.min(code, 6)]!);
        sign ^= -(code & 1);
        dc[i] = dc[i - 1]! + (((code + 1) >> 1) ^ sign) - sign;
    }

    const quantized = new Int32Array(numDcs);
    for (let i = 0; i < numDcs; i++) {
        quantized[i] = 4096 + ((dc[i]! * qMatLuma![0]! * scaleFactor) >> 2);
    }

    console.log(quantized)

    pos = startPos + sliceSizes[i]!;
    break;
}