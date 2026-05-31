import { ALL_FORMATS, EncodedPacketSink, FilePathSource, Input, UrlSource } from 'mediabunny';

const input = new Input({
    source: new UrlSource('./IMG_0159-prores-hdr.MOV'),
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
} else {
    qMatLuma = new Uint8Array(64).fill(4);
}
if (qMatFlags & 0b01) {
    qMatChroma = packetData.subarray(pos, pos + 64);
    pos += 64;
} else {
    qMatChroma = new Uint8Array(64).fill(4);
}

console.log(hdrSize, version, creatorId, frameWidth, frameHeight, chrominanceFactor, frameType, primaries, transferFunction, colorMatrix, srcPixFormat, alphaInfo, qMatFlags, qMatLuma, qMatChroma);

const canvas = document.createElement('canvas');
canvas.width = frameWidth;
canvas.height = frameHeight;
const context = canvas.getContext('2d', { alpha: false })!;
document.body.append(canvas);

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

console.time()

for (let i = 0; i < totalSlices; i++) {
    let sliceX = (i * sliceWidth * 16) % frameWidth; // temp
    let sliceY = Math.floor(i * sliceWidth * 16 / frameWidth) * sliceHeight * 16;

    const startPos = pos;
    const sliceHdrSize = dataView.getUint8(pos); pos += 1;
    let scaleFactor = dataView.getUint8(pos); pos += 1;
    if (scaleFactor > 128) scaleFactor = (scaleFactor - 96) << 2;
    const lumaDataSize = dataView.getUint16(pos); pos += 2;
    const uDataSize = dataView.getUint16(pos); pos += 2;

    //console.log("luma data size", lumaDataSize);
    
    //console.log(sliceHdrSize, scaleFactor, lumaDataSize, uDataSize);

    const bitStartPos = pos;
    let bitPos = 8 * bitStartPos;

    const getRemainingBits = () => {
        return 8 * (bitStartPos + lumaDataSize) - bitPos;
    };

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

    const peekBits = (n: number) => {
        const result = getBits(n);
        bitPos -= n;

        return result;
    };

    const getUnary = () => {
        let res = 0;
        while (!getBit()) {
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
            bitPos -= n + 1;
            const bits = g - mp + (n<<1);
            return getBits(bits) - (1 << g) + ((mp + 1) << r);
        } else if (r > 0) {
            return (n << r) | getBits(r);
        } else {
            return n;
        }
    };

    const numBlocks = sliceWidth * sliceHeight * 4; // 4 luma blocks per macroblock
    const dcCodeParams = [0x04, 0x28, 0x28, 0x4D, 0x4D, 0x70, 0x70];
    let code = getCode(0xB8);
    console.log("first", code)

    const blocks = new Float32Array(64 * sliceWidth * sliceHeight * 4); // 4 luma blocks per macroblock

    //const dc = new Int32Array(numDcs);
    blocks[0] = (code >> 1) ^ -(code & 1);

    code = 5;
    let sign = 0;
    for (let i = 1; i < numBlocks; i++) {
        code = getCode(dcCodeParams[Math.min(code, 6)]!);
        if(code) sign ^= -(code & 1);
        else     sign  = 0;
        //sign ^= -(code & 1);
        blocks[64 * i] = blocks[64 * (i - 1)]! + (((code + 1) >> 1) ^ sign) - sign;
    }

    if (true) {
        //const ProresContext *ctx = avctx->priv_data;
        //int block_mask, sign;
        //unsigned pos, run, level;
        //int max_coeffs, i, bits_left;
        //int log2_block_count = av_log2(blocks_per_slice);

        //OPEN_READER(re, gb);
        //UPDATE_CACHE_32(re, gb);
        let run   = 4;
        let level = 2;
        //let sign = 0;

        const run_to_cb = [ 0x06, 0x06, 0x05, 0x05, 0x04, 0x29, 0x29, 0x29, 0x29, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x4C ];
        const lev_to_cb = [ 0x04, 0x0A, 0x05, 0x06, 0x04, 0x28, 0x28, 0x28, 0x28, 0x4C ];

        const scanOrder = [
            0,  1,  8,  9,  2,  3, 10, 11,
            16, 17, 24, 25, 18, 19, 26, 27,
            4,  5, 12, 20, 13,  6,  7, 14,
            21, 28, 29, 22, 15, 23, 30, 31,
            32, 33, 40, 48, 41, 34, 35, 42,
            49, 56, 57, 50, 43, 36, 37, 44,
            51, 58, 59, 52, 45, 38, 39, 46,
            53, 60, 61, 54, 47, 55, 62, 63,
        ];
        const scanOrderInverse = Array.from({ length: 64 }).fill(0);
        for (let i = 0; i < 64; i++) {
            scanOrderInverse[scanOrder[i]!] = i;
        }

        const log2_block_count = Math.floor(Math.log2(numBlocks));
        const max_coeffs = 64 << log2_block_count;

        const blockMask = numBlocks - 1;
        let pos = blockMask;

        while (true) {
            const bitsLeft = getRemainingBits();// gb->size_in_bits - re_index;
            if (bitsLeft <= 0 || (bitsLeft < 32 && peekBits(bitsLeft) === 0)) {
                break;
            }

            run = getCode(run_to_cb[Math.min(run, 15)]!);
            //DECODE_CODEWORD(run, run_to_cb[FFMIN(run,  15)], LAST_SKIP_BITS);
            pos += run + 1;
            if (pos >= max_coeffs) {
                throw new Error('ac text damaged');
            }

            level = getCode(lev_to_cb[Math.min(level, 9)]!);
            //DECODE_CODEWORD(level, lev_to_cb[FFMIN(level, 9)], SKIP_BITS);
            level += 1;

            const i = pos >> log2_block_count;

            const sign = -getBit();

            //sign = SHOW_SBITS(re, gb, 1);
            //SKIP_BITS(re, gb, 1);
            blocks[((pos & blockMask) << 6) + scanOrder[i]!] = (level ^ sign) - sign;

            //out[((pos & block_mask) << 6) + ctx->scan[i]] = ((level ^ sign) - sign);
        }

        //CLOSE_READER(re, gb);
        //return 0;
    }

    for (let i = 0; i < numBlocks; i++) {
        for (let j = 0; j < 64; j++) {
            if (j === 0) {
                blocks[64 * i + j] = 4096 + ((blocks[64 * i + j]! * qMatLuma![j]! * scaleFactor) >> 2);
            } else {
                blocks[64 * i + j] = (blocks[64 * i + j]! * qMatLuma![j]! * scaleFactor) >> 2;
            }
        }
    }

    const S = [
        0.353553390593273762200422,
        0.254897789552079584470970,
        0.270598050073098492199862,
        0.300672443467522640271861,
        0.353553390593273762200422,
        0.449988111568207852319255,
        0.653281482438188263928322,
        1.281457723870753089398043,
    ];

    const A = [
        NaN,
        0.707106781186547524400844,
        0.541196100146196984399723,
        0.707106781186547524400844,
        1.306562964876376527856643,
        0.382683432365089771728460,
    ];

    function FastDct8_inverseTransform(vector: Float32Array) {
        const v15 = vector[0]! / S[0]!;
        const v26 = vector[1]! / S[1]!;
        const v21 = vector[2]! / S[2]!;
        const v28 = vector[3]! / S[3]!;
        const v16 = vector[4]! / S[4]!;
        const v25 = vector[5]! / S[5]!;
        const v22 = vector[6]! / S[6]!;
        const v27 = vector[7]! / S[7]!;
        
        const v19 = (v25 - v28) / 2;
        const v20 = (v26 - v27) / 2;
        const v23 = (v26 + v27) / 2;
        const v24 = (v25 + v28) / 2;
        
        const v7  = (v23 + v24) / 2;
        const v11 = (v21 + v22) / 2;
        const v13 = (v23 - v24) / 2;
        const v17 = (v21 - v22) / 2;
        
        const v8 = (v15 + v16) / 2;
        const v9 = (v15 - v16) / 2;
        
        const v18 = (v19 - v20) * A[5]!;  // Different from original
        const v12 = (v19 * A[4]! - v18) / (A[2]! * A[5]! - A[2]! * A[4]! - A[4]! * A[5]!);
        const v14 = (v18 - v20 * A[2]!) / (A[2]! * A[5]! - A[2]! * A[4]! - A[4]! * A[5]!);
        
        const v6 = v14 - v7;
        const v5 = v13 / A[3]! - v6;
        const v4 = -v5 - v12;
        const v10 = v17 / A[1]! - v11;
        
        const v0 = (v8 + v11) / 2;
        const v1 = (v9 + v10) / 2;
        const v2 = (v9 - v10) / 2;
        const v3 = (v8 - v11) / 2;
        
        vector[0] = (v0 + v7) / 2;
        vector[1] = (v1 + v6) / 2;
        vector[2] = (v2 + v5) / 2;
        vector[3] = (v3 + v4) / 2;
        vector[4] = (v3 - v4) / 2;
        vector[5] = (v2 - v5) / 2;
        vector[6] = (v1 - v6) / 2;
        vector[7] = (v0 - v7) / 2;
    }

    function dct8x8(block: Float32Array) {
        for (let row = 0; row < 8; row++) {
            FastDct8_inverseTransform(block.subarray(8 * row, 8 * row + 8));
        }

        const temp = new Float32Array(8);
        for (let column = 0; column < 8; column++) {
            temp[0] = block[0 * 8 + column]!;
            temp[1] = block[1 * 8 + column]!;
            temp[2] = block[2 * 8 + column]!;
            temp[3] = block[3 * 8 + column]!;
            temp[4] = block[4 * 8 + column]!;
            temp[5] = block[5 * 8 + column]!;
            temp[6] = block[6 * 8 + column]!;
            temp[7] = block[7 * 8 + column]!;

            FastDct8_inverseTransform(temp);

            block[0 * 8 + column] = temp[0];
            block[1 * 8 + column] = temp[1];
            block[2 * 8 + column] = temp[2];
            block[3 * 8 + column] = temp[3];
            block[4 * 8 + column] = temp[4];
            block[5 * 8 + column] = temp[5];
            block[6 * 8 + column] = temp[6];
            block[7 * 8 + column] = temp[7];
        }
    }

    for (let i = 0; i < numBlocks; i++) {
        dct8x8(blocks.subarray(64 * i, 64 * i + 64));
        //const quantized = 4096 + ((blocks[64 * i]! * qMatLuma![0]! * scaleFactor) >> 2);

        let blockOffsetX = Math.floor(i / 4) * 16 + (i % 2) * 8;
        let blockOffsetY = (i % 4 < 2 ? 0 : 8);
        let blockX = sliceX + blockOffsetX;
        let blockY = sliceY + blockOffsetY;

        for (let j = 0; j < 64; j++) {
            const normalized = blocks[64 * i + j]! / 1024;
            const r = Math.min(255, Math.max(0, Math.floor((normalized) * 255)));
            context.fillStyle = `rgb(${r},${r},${r})`;
            context.fillRect(blockX + j % 8, blockY + Math.floor(j / 8), 1, 1);
        }
    }

    pos = startPos + sliceSizes[i]!;
    //break;
    if (i === 8) {
        //break;
    }
}

console.timeEnd()