import { ALL_FORMATS, EncodedPacketSink, FilePathSource, Input, UrlSource } from 'mediabunny';
import { initWasmModule } from './wasm-init';

const memory = new WebAssembly.Memory({ initial: 32, maximum: 65536, shared: true });

const exports = await initWasmModule(memory);
console.log(exports)

exports.__wasm_init_tls(exports.allocateThreadLocalState(exports.__tls_size.value, exports.__tls_align.value));

const concurrency = navigator.hardwareConcurrency;
const workers: Worker[] = [];
const promises: Promise<void>[] = [];

for (let i = 0; i < concurrency; i++) {
	const stackPointer = exports.allocateWorkerStack();
	const tlsPointer = exports.allocateThreadLocalState(exports.__tls_size.value, exports.__tls_align.value);

	const worker = new Worker('./worker.ts', { type: 'module' });
	worker.postMessage({ memory, stackPointer, tlsPointer });

	promises.push(new Promise(resolve => {
		worker.addEventListener('message', () => resolve());
	}));
}

await Promise.all(promises);

const decoder = exports.createDecoder();
console.log(decoder)

//await new Promise(() => {});

const input = new Input({
    source: new UrlSource('./IMG_0159-prores-hdr.MOV'),
    formats: ALL_FORMATS,
});

const addr = exports.getWaitWordAddress(decoder);

const videoTrack = (await input.getPrimaryVideoTrack())!;
const sink = new EncodedPacketSink(videoTrack);

const decode = async () => {
	exports.decodePacket(decoder)
	await Atomics.waitAsync(new Int32Array(memory.buffer), addr / 4, 0).value;
};

const canvas = document.createElement('canvas');
const context = canvas.getContext('2d')!;
document.body.append(canvas);

const start = performance.now();
let total = 0;

const packetDatas: Uint8Array[] = [];
for await (const packet of sink.packets()) {
	packetDatas.push(packet.data);
}

const fileIters = 10;

for (let i = 0; i < fileIters; i++) {
	for (const packetData of packetDatas) {
		//console.log(packet.data.byteLength)
		const packetPtr = exports.allocatePacket(decoder, packetData.byteLength);
		new Uint8Array(memory.buffer).set(packetData, packetPtr);

		await decode();

		total++;
		continue;

		canvas.width = exports.getDisplayWidth(decoder);
		canvas.height = exports.getDisplayHeight(decoder);

		const codedWidth = exports.getCodedWidth(decoder);
		const codedHeight = exports.getCodedHeight(decoder);
		const frameDataPtr = exports.getFrameDataPtr(decoder);
		const frameData = new Uint16Array(memory.buffer, frameDataPtr, 2 * codedWidth * codedHeight);
		//console.log(frameData);

		const frame = new VideoFrame(frameData, {
			format: 'I422P10' as VideoPixelFormat,
			codedWidth,
			codedHeight,
			timestamp: 0,
			duration: 0,
			colorSpace: {
				primaries: 'bt2020',
				transfer: 'hlg',
				matrix: 'bt2020-ncl',
				fullRange: true,
			},
		});

		context.drawImage(frame, 0, 0);
		frame.close();
	}
}

console.log(packetDatas.length);
alert((performance.now() - start) / fileIters);
//const packet = (await sink.getFirstPacket())!;

//await new Promise(() => {});





/*
const tryhard = true;

if (tryhard) {
	const warmup = 20;
	for (let i = 0; i < warmup; i++) {
		await decode();
		//console.log("Decode result", exports.decodePacket(decoder));
	}
}

const start = performance.now();
const iters = tryhard ? 500 : 1;

for (let i = 0; i < iters; i++) {
	await decode();
	//console.log("Decode result", exports.decodePacket(decoder));
}

const end = performance.now();

//console.log((end - start) / iters);

setTimeout(() => {
	alert((end - start) / iters);
});
*/

//await new Promise((resolve) => setTimeout(resolve, 500));






// Each element in frameData contains a float from 0-1. Paint as grayscale image to canvas using putImageData
//const imageData = context.createImageData(codedWidth, codedHeight);
//for (let i = 0; i < frameData.length; i++) {
//	const value = Math.round(255 * frameData[i]! / 1023);
//	imageData.data[i * 4] = value;
//	imageData.data[i * 4 + 1] = value;
//	imageData.data[i * 4 + 2] = value;
//	imageData.data[i * 4 + 3] = 255;
//}
//context.putImageData(imageData, 0, 0);