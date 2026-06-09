import { ALL_FORMATS, EncodedPacketSink, Input, UrlSource } from 'mediabunny';
import { createDecoder } from './src/index';

const decoder = await createDecoder({});
if (decoder instanceof Error) {
    throw decoder;
}

const input = new Input({
    source: new UrlSource('./prores-transparent-2.mov'),
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

for (const packetData of packetDatas) {
    const result = await decoder.decode(packetData);
    if (result instanceof Error) {
        throw result;
    }

    console.log(result)

    total++;
}

console.log(packetDatas.length);
alert((performance.now() - start) / total);
