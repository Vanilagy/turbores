import { ALL_FORMATS, EncodedPacketSink, Input, UrlSource } from 'mediabunny';
import { createDecoder } from './src/index';

const decoder = await createDecoder({});
if (decoder instanceof Error) {
    throw decoder;
}

const canvas = document.createElement('canvas');
document.body.append(canvas);
const ctx = canvas.getContext('2d');

const input = new Input({
    source: new UrlSource('./IMG_0159-prores-hdr.MOV'),
    formats: ALL_FORMATS,
});

const videoTrack = (await input.getPrimaryVideoTrack())!;
const sink = new EncodedPacketSink(videoTrack);

const packetDatas: Uint8Array[] = [];
for await (const packet of sink.packets()) {
    packetDatas.push(packet.data);
}

const start = performance.now();
let total = 0;

const fileIters = 200;

for (let i = 0; i < fileIters; i++) {
    for (const packetData of packetDatas) {
        const result = await decoder.decode(packetData);
        if (result instanceof Error) {
            throw result;
        }

        //console.log(result)
    
        total++;
    
        break;

        canvas.width = result.displayWidth;
        canvas.height = result.displayHeight;

        const frame = new VideoFrame(result.frameData, {
            format: result.pixelFormat,
            codedWidth: result.codedWidth,
            codedHeight: result.codedHeight,
            displayWidth: result.displayWidth,
            displayHeight: result.displayHeight,
            timestamp: 0,
            duration: 0,
        });
        ctx!.drawImage(frame, 0, 0);
        frame.close();

        //break;
    }
}

console.log(packetDatas.length);
alert((performance.now() - start) / total);
