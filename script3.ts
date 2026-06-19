import { ALL_FORMATS, EncodedPacketSink, Input, UrlSource } from 'mediabunny';
import { Decoder, Frame } from './src/index';

const decoder = await Decoder.create({ proresFourCc: 'apch', useSharedMemory: true });
if (decoder instanceof Error) {
    throw decoder;
}

const canvas = document.getElementById('canvas') as HTMLCanvasElement;
const ctx = canvas.getContext('2d')!;
const scrubber = document.getElementById('scrubber') as HTMLInputElement;

const input = new Input({
    source: new UrlSource('./IMG_0164.MOV'),
    formats: ALL_FORMATS,
});

const videoTrack = (await input.getPrimaryVideoTrack())!;
const sink = new EncodedPacketSink(videoTrack);

scrubber.max = String(await videoTrack.computeDuration());

const frame = new Frame();
let pendingTimestamp: number | null = null;
let busy = false;

const renderLoop = async () => {
    if (busy || pendingTimestamp === null) {
        return;
    }

    busy = true;
    while (pendingTimestamp !== null) {
        const timestamp = pendingTimestamp;
        pendingTimestamp = null;

        const packet = await sink.getPacket(timestamp);
        if (!packet) {
            continue;
        }

        const result = await decoder.decode(packet.data, frame);
        if (result instanceof Error) {
            throw result;
        }

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
        });
        ctx.drawImage(videoFrame, 0, 0);
        videoFrame.close();
    }
    busy = false;
};

scrubber.addEventListener('input', () => {
    pendingTimestamp = Number(scrubber.value);
    void renderLoop();
});

pendingTimestamp = 0;
void renderLoop();
