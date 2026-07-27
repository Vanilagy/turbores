Use `benchmark-turbores.html`, `benchmark-ffmpeg-wasm.html` and `benchmark-ffmpeg-native.sh` to benchmark TurboRes, ffmpeg.wasm and native FFmpeg (via the CLI) respectively. They all measure the time it takes to decode a given file ten times and use that to determine decoding speed.

## HTML benchmarks (TurboRes/FFmpeg WASM)

The HTML files have instructions on the page. Make sure to run them with the console closed, as an open console slows down WASM execution. To change the number of threads, you must modify the HTML.

For benchmarking TurboRes, you must first build it via `./scripts/build-zig.sh --release`.

## TurboRes native benchmark

For the TurboRes native shell script, the usage is:
```bash
./benchmark-turbores-native.sh -t <threads> <video-file>
```

Before running the script, you must build TurboRes via `./scripts/build-zig.sh --target <target> --dynamic --release` where `<target>` is one of:
- `aarch64-macos`
- `x86_64-macos`
- `aarch64-linux`
- `x86_64-linux`
- `aarch64-windows`
- `x86_64-windows`

## FFmpeg native benchmark

For the FFmpeg shell script, the usage is:
```bash
./benchmark-ffmpeg-native.sh -t <threads> [-a] <video-file>
```
Required FFmpeg to be installed. Supply `-a` to test with hardware acceleration. Requires running on a Mac with VideoToolbox available.

## Files

The files used for the benchmark are:
- ProRes 422 HQ @ 4K: https://pub-1ee78aacb848486482b20a72b55b3121.r2.dev/IMG_1846_4k.mov
- ProRes 4444 @ 1080p: https://pub-1ee78aacb848486482b20a72b55b3121.r2.dev/prores-transparent-2.mov
- ProRes 422 HQ @ 1080p: https://pub-1ee78aacb848486482b20a72b55b3121.r2.dev/IMG_1846_1080p.mov
- ProRes 422 Proxy @ 1080p: https://pub-1ee78aacb848486482b20a72b55b3121.r2.dev/IMG_1846_1080p_proxy.mov