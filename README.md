# TurboRes

[![](https://img.shields.io/npm/v/turbores)](https://www.npmjs.com/package/turbores)
[![](https://img.shields.io/bundlephobia/minzip/turbores)](https://bundlephobia.com/package/turbores)
[![](https://img.shields.io/npm/dm/turbores)](https://www.npmjs.com/package/turbores)
[![](https://img.shields.io/discord/1390044844285497344?logo=discord&label=Discord)](https://discord.gg/hmpkyYuS4U)

TurboRes is an extremely fast Apple ProRes video decoder library for browsers and other JavaScript environments. It is written from scratch in Zig and TypeScript. Its goal is enabling high-performance processing of ProRes media in browsers without the need for hardware acceleration.

TurboRes is:
- **Fast.** With both impressive single- and multi-core performance, TurboRes can decode even high-quality 4K videos at hundreds of frames per second and is [more than twice as fast as native FFmpeg](#performance).
- **Feature-rich.** TurboRes supports all ProRes variants: 422/444 High Quality, Standard Definition, LT & Proxy, as well as transparent ProRes 4444, with both 10-bit and 12-bit color depths, progressive or interlaced, at all resolutions up to 16K. Additional features include explicit concurrency control and zero-overhead pixel format conversions.
- **Correct.** TurboRes provides bit-exact decode results and does not approximate.
- **Robust.** TurboRes fully validates all input and gracefully rejects any corrupted or malicious data.
- **Portable.** TurboRes runs everywhere out of the box: Chromium, Firefox, Safari, Node, Deno, Bun.
- **Simple.** Very minimal API with easy interop with the WebCodecs API and [Mediabunny](https://mediabunny.dev/).
- **Tiny.** The gzipped bundle is smaller than 50 kB.

> This project was fully enabled by generous donations by sponsors. If you've derived value from this package, please consider [leaving a donation](https://github.com/sponsors/Vanilagy)! 💘

## Motivation

As the author of [Mediabunny](https://mediabunny.dev/), I regularly get requests for adding ProRes support to the library. I initially tried doing this by using ffmpeg.wasm, but the performance was insufficient for real-time applications. Knowing that FFmpeg wasn't originally built with WASM in mind, I suspected that a custom-built solution would probably beat it. So, my goals for this library were twofold:

- Learn how video decoders work and build one from scratch, ideally with minimal AI assistance
- Build a relentlessly-optimized ProRes decoder capable of faster-than-real-time video decoding in browsers

It started mainly as a hobby experiment and learning exercise, but since the performance ended up being extremely competitive, I ultimately turned it into a polished library.

## Usage

```bash
npm install turbores
```

```ts
import { Decoder, Frame } from 'turbores';

// Create a decoder for each stream you want to decode
const decoder = await Decoder.create({
    // The FourCC identifying the ProRes variant, usually found as metadata
    // within the file that contains the ProRes media. When not available,
    // 'apch' is a good default.
    proresFourCc: 'apch',

    // Whether to use shared-memory multithreading. Recommended for best
    // performance, but requires cross-origin isolation.
    useSharedMemory: true,
});
if (decoder instanceof Error) {
    // Handle the error...
}

// Create a frame to hold the output data
const frame = new Frame();

const result = await decoder.decode(
    packetData, // Uint8Array containing a single ProRes frame
    frame,
);
if (result instanceof Error) {
    // Handle the error...
}
```

You can extract the encoded packets from a media file using a library like [Mediabunny](https://mediabunny.dev/).

`result` is now the decoded frame of type `FilledFrame`. An HDR 1080p frame might look like:
```ts
result.frameData; // => Uint8Array
result.pixelFormat; // => 'I422P10'
result.scanType; // => 'progressive'

result.codedWidth; // => 1920
result.codedHeight; // => 1088
result.visibleWidth; // => 1920
result.visibleHeight; // => 1080

result.colorPrimaries; // => 9 (ITU-R BT.2020)
result.colorTransfer; // => 18 (ARIB STD-B67 (HLG))
result.colorMatrix; // => 9 (BT2020 Non-constant Luminance)
result.colorRangeFull; // => false
```

The frame's data is valid until it is used for a new decoding task. If you need to keep multiple frames around at the same time, create multiple `Frame` instances.

When done, you **should** close all frames and decoders to free internally-held resources:
```ts
frame.clear();
decoder.close();
```

### Errors

TurboRes uses _errors as values_, meaning functions return either the result or an error. The following errors may occur during operation:
- `OutOfMemoryError`: The decoder ran out of memory.
- `UnexpectedEofError`: The packet ended before the decoder expected it to.
- `InvalidDataError`: The packet contains invalid or corrupted data.
- `NotSupportedError`: The packet uses a feature that the decoder doesn't support.
- `InvalidStateError`: The decoder is in an invalid internal state. This should never happen and should be reported.
- `DecoderClosedError`: An operation was attempted on a decoder that has already been closed.
- `FrameLockedError`: A frame was used while it is locked by an in-flight decoding operation.

Since errors are returned plainly, you can check for them using a simple `instanceof` check.

### Multithreading

TurboRes can use multiple threads to run faster. It has two systems for doing this:
- **Shared-memory multithreading:** Here, all threads operate on the same memory and can split up the work of decoding a single ProRes packet. This is the fastest option with the least overhead, and provides extremely low latency since multiple threads attack the same packet.
- **Worker pool-based multithreading:** Here, multiple workers are created, each of which decodes a packet fully by itself. When multiple packets are decoded in quick succession, the packets are distributed to multiple workers so they can decode frames in parallel. This variant has higher decoding latency and overhead due to message passing.

---

Enable shared-memory multithreading like so:
```ts
const decoder = await Decoder.create({
    useSharedMemory: true,
    // ...
});
```
When run in a browser, this requires the page to be [cross-origin isolated](https://developer.mozilla.org/en-US/docs/Web/API/Window/crossOriginIsolated). This can be done by setting the following HTTP response headers:
```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Alternatively, you can use:
```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: credentialless
```
which is generally more permissive but is not supported in Safari (of course).

---

Control the number of threads via the `concurrency` option:
```ts
const decoder = await Decoder.create({
    useSharedMemory: true,
    concurrency: 8, // Use 8 threads. Defaults to `navigator.hardwareConcurrency`. 
});
```

To force synchronous decoding, set `concurrency` to zero:
```ts
const decoder = await Decoder.create({
    useSharedMemory: true, // or false, doesn't matter
    concurrency: 0,
});
```

Message passing is never required for synchronous decoding, but it will block the main thread.

### Pixel format conversions

TurboRes is able to perform pixel format conversions at _no additional cost_. This is useful for when your consuming code cannot support the pixel formats typically emitted by ProRes, such as `I422P10`.

To convert to a desired pixel format, use:
```ts
const decoder = await Decoder.create({
    // This FORCES the decoder to output all frames in I420:
    allowedOutputFormats: ['I420'],
});
```

You can specify multiple format options:
```ts
const decoder = await Decoder.create({
    allowedOutputFormats: ['I420', 'I420A', 'I422P10', 'I422AP10'],
});
```

When the native pixel format is allowed, the decoder will choose that. Otherwise, it will choose an alternative format that minimizes data loss according to an internal heuristic.

The list of available pixel formats is given by this regex:
```ts
/^I(420|422|444)A?(P10|P12)?$/
```

### Packet queueing

Multiple packets can be queued for decoding:
```ts
const frame1 = new Frame();
const frame2 = new Frame();
const frame3 = new Frame();

const promise1 = decoder.decode(packetData1, frame1);
const promise2 = decoder.decode(packetData2, frame2);
const promise3 = decoder.decode(packetData3, frame3);

// You can use these to inspect the decoder's decode queue:
decoder.decodeQueueSize; // => 3
await decoder.dequeued;
decoder.decodeQueueSize; // => 2
await decoder.dequeued;
decoder.decodeQueueSize; // => 1
await decoder.dequeued;
decoder.decodeQueueSize; // => 0
```

Decoding jobs will always resolve in the order in which they were queued, meaning `promise1` will resolve before `promise2`, which will resolve before `promise3`.

## Performance

As the name suggests, TurboRes is extremely performant and can decode ProRes at speeds exceeding 1 GB/s. The following benchmarks compare it to the native FFmpeg CLI and ffmpeg.wasm:

| | ProRes 422 HQ @ 4K | ProRes 4444 @ 1080p | ProRes 422 HQ @ 1080p | ProRes 422 Proxy @ 1080p |
| - | - | - | - | - |
| **TurboRes, multithreaded** | **228 FPS** | **710 FPS** | **803 FPS** | **2126 FPS** |
| FFmpeg native, hardware-accelerated | 160 FPS | 256 FPS | 464 FPS | 466 FPS |
| FFmpeg native, multithreaded | 107 FPS | 342 FPS | 375 FPS | 948 FPS |
| ffmpeg.wasm, multithreaded | 84 FPS | 288 FPS | 295 FPS | 706 FPS |
|  |  |  |  |  |
| **TurboRes, singlethreaded** | **40 FPS** | **127 FPS** | **146 FPS** | **430 FPS** |
| FFmpeg native, singlethreaded | 15 FPS | 55 FPS | 57 FPS | 161 FPS |
| ffmpeg.wasm, singlethreaded | 13 FPS | 50 FPS | 48 FPS | 131 FPS |

> Averaged over 10 runs. Higher is better. Measured on an M4 (4P+6E) MacBook Air. \
> To reproduce these benchmarks, check out [`benchmark/README.md`](./benchmark/README.md).

## Under the hood

TurboRes easily beats native FFmpeg in performance, which is the result of relentless optimization to make the most out of every CPU cycle. Here's a quick summary of the techniques used:

- The decoding logic is entirely written in Zig, the primary benefit of which is that it emits WebAssembly. WASM via Zig enables a range of features that JavaScript doesn't have, such as manual memory management, SIMD instructions, and easy-to-use shared-memory multithreading.
- Decoding packets allocates no memory after the first packet and uses barely any additional memory besides storing input and output.
- Entropy decoding of DC and AC coefficients is almost fully branchless and makes use of ILP (instruction-level parallelism) to decode multiple streams at once on a single CPU core.
- Bits are read from the data using a 64-bit accumulator-based method while minimizing memory reads.
- The Inverse Discrete Cosine Transform step makes use of fast SIMD float arithmetic, which beats integer SIMD in WASM.
- The IDCT itself uses the fast 8x8 AAN (Arai, Agui, Nakajima) algorithm with all scaling factors and dequantization matrices baked into a single initial scaling step.
- The 8x8 transpose is fully vectorized and so is the final conversion to 16-bit integers.
- Memory writes to the frame data always use the 128-bit WASM vector type.
- Frames are split up across threads dynamically such that no thread is ever idle.
- Pixel format conversions are directly baked into the decoding step, meaning they have no additional overhead.
- The code itself makes heavy use of inlining and comptime-evaluation, which allows LLVM to better understand data dependencies and output faster code.

## License

TurboRes is licensed under the [Mozilla Public License 2.0](https://www.mozilla.org/en-US/MPL/2.0/), which permits both private and commercial use, but requires that any modifications to MPL-covered files be made available to recipients when the software is distributed.

## Building and development

This project requires Zig 0.16 and a modern version of Node and npm. To set it up locally, clone the repo, then run `npm install`.

Use `npm run dev` to start the Vite development server, which you can then use to serve any HTML files in this project.

Use `./scripts/build-zig.sh` to compile the Zig code into a debug build, or use `./scripts/build-zig.sh --release` to create an optimized release build.

Use `npm run build` to build the final library.

Use `npm run check` and `npm run lint` to perform typechecking and linting on the project.

Use `npm test` to run the full test suite using the Zig debug build.

Use `npm run demo:dev` and `npm run demo:build` to run and build the demo. Working with the demo assumes that the Zig code has already been built.

## References

The following resources helped me realize this project:
- https://web.archive.org/web/20250802070520/https://wiki.multimedia.cx/index.php/Apple_ProRes
- https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/proresdec.c