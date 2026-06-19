import { ALL_FORMATS, EncodedPacketSink, FilePathSource, Input, UrlSource } from 'mediabunny';
import { Decoder, Frame } from './src/index';

const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: false });
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

const fileIters = 100;

const frame = new Frame();

for (let i = 0; i < fileIters; i++) {
    for (const packetData of packetDatas) {
        const result = await decoder.decode(packetData, frame);
        if (result instanceof Error) {
            throw result;
        }

        //console.log(result)

        total++;

        break;

        canvas.width = result.visibleWidth;
        canvas.height = result.visibleHeight;

        const videoFrame = new VideoFrame(result.frameData, {
            format: result.pixelFormat,
            codedWidth: result.codedWidth,
            codedHeight: result.codedHeight,
            visibleRect: {
                x: 0,
                y: 0,
                width: result.visibleWidth,
                height: result.visibleHeight,
            },
            timestamp: 0,
            duration: 0,
        });
        ctx!.drawImage(videoFrame, 0, 0);
        videoFrame.close();

        break;
    }
}

//console.log(packetDatas.length, (performance.now() - start) / total);
alert((performance.now() - start) / total);
