import { Decoder } from './decoder';
import { getRuntime } from './runtime';

export type { Decoder, DecodeResult, PixelFormat } from './decoder';

export type DecoderOptions = {};

export const createDecoder = async (options: DecoderOptions = {}): Promise<Decoder | Error> => {
    void options;

    const runtime = await getRuntime();
    if (runtime instanceof Error) {
        return runtime;
    }

    return new Decoder(runtime, runtime.exports.createDecoder());
};
