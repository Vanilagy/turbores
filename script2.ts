import { ALL_FORMATS, EncodedPacketSink, FilePathSource, Input, UrlSource } from 'mediabunny';

// https://gist.github.com/pascaldekloe/62546103a1576803dade9269ccf76330
const decodeUtf8 = (bytes: Uint8Array) => {
	let i = 0, s = '';

	while (i < bytes.length) {
		var c = bytes[i++]!;
		if (c > 127) {
			if (c > 191 && c < 224) {
				if (i >= bytes.length)
					throw new Error('UTF-8 decode: incomplete 2-byte sequence');
				c = (c & 31) << 6 | bytes[i++]! & 63;
			} else if (c > 223 && c < 240) {
				if (i + 1 >= bytes.length)
					throw new Error('UTF-8 decode: incomplete 3-byte sequence');
				c = (c & 15) << 12 | (bytes[i++]! & 63) << 6 | bytes[i++]! & 63;
			} else if (c > 239 && c < 248) {
				if (i + 2 >= bytes.length)
					throw new Error('UTF-8 decode: incomplete 4-byte sequence');
				c = (c & 7) << 18 | (bytes[i++]! & 63) << 12 | (bytes[i++]! & 63) << 6 | bytes[i++]! & 63;
			} else throw new Error('UTF-8 decode: unknown multibyte start 0x' + c.toString(16) + ' at index ' + (i - 1));
		}
		if (c <= 0xffff) s += String.fromCharCode(c);
		else if (c <= 0x10ffff) {
			c -= 0x10000;
			s += String.fromCharCode(c >> 10 | 0xd800)
			s += String.fromCharCode(c & 0x3FF | 0xdc00)
		} else throw new Error('UTF-8 decode: code point 0x' + c.toString(16) + ' exceeds UTF-16 reach');
	}

	return s;
}

const memory = new WebAssembly.Memory({ initial: 128 });
const module = await WebAssembly.instantiateStreaming(fetch('./lib.wasm'), {
    env: {
        memory,
        externPrint: (offset: number, length: number) => {
            const bytes = new Uint8Array(memory.buffer, offset, length);
            console.log(decodeUtf8(bytes));
        },
		consoleTime: console.time,
		consoleTimeEnd: console.timeEnd,
    },
});

const exports = module.instance.exports as {
    createDecoder: () => number,
    allocatePacket: (decoder: number, size: number) => number,
    decodePacket: (decoder: number) => void,
	getDisplayWidth: (decoder: number) => number,
	getDisplayHeight: (decoder: number) => number,
	getCodedWidth: (decoder: number) => number,
	getCodedHeight: (decoder: number) => number,
	getFrameDataPtr: (decoder: number) => number,
};

const decoder = exports.createDecoder();
console.log(decoder)

const input = new Input({
    source: new UrlSource('./IMG_0159-prores-hdr.MOV'),
    formats: ALL_FORMATS,
});

const videoTrack = (await input.getPrimaryVideoTrack())!;
const sink = new EncodedPacketSink(videoTrack);
const packet = (await sink.getFirstPacket())!;

//await new Promise(() => {});

const packetPtr = exports.allocatePacket(decoder, packet.byteLength);
new Uint8Array(memory.buffer).set(packet.data, packetPtr);

const start = performance.now();
const iters = 500;

for (let i = 0; i < iters; i++) {
	console.log("Decode result", exports.decodePacket(decoder));
}

alert((performance.now() - start) / iters);

const canvas = document.createElement('canvas');
canvas.width = exports.getDisplayWidth(decoder);
canvas.height = exports.getDisplayHeight(decoder);

document.body.append(canvas);

const context = canvas.getContext('2d')!;

const codedWidth = exports.getCodedWidth(decoder);
const codedHeight = exports.getCodedHeight(decoder);
const frameDataPtr = exports.getFrameDataPtr(decoder);
const frameData = new Int32Array(memory.buffer, frameDataPtr, codedWidth * codedHeight);

// Each element in frameData contains a float from 0-1. Paint as grayscale image to canvas using putImageData
const imageData = context.createImageData(codedWidth, codedHeight);
for (let i = 0; i < frameData.length; i++) {
	const value = Math.round(255 * frameData[i]! / 1023);
	imageData.data[i * 4] = value;
	imageData.data[i * 4 + 1] = value;
	imageData.data[i * 4 + 2] = value;
	imageData.data[i * 4 + 3] = 255;
}
context.putImageData(imageData, 0, 0);