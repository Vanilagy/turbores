Use `benchmark-turbores.html`, `benchmark-ffmpeg-wasm.html` and `benchmark-ffmpeg-native.sh` to benchmark TurboRes, ffmpeg.wasm and native FFmpeg (via the CLI) respectively. They all measure the time it takes to decode a given file ten times and use that to determine decoding speed.

---

The HTML files have instructions on the page. For the shell script, the usage is:
```bash
./benchmark-ffmpeg-native.sh -t <threads> [-a] <video-file>
```
Supply `-a` to test with hardware acceleration. Requires running on a Mac with VideoToolbox available.

---

The files used for the benchmark are:
- ProRes 422 HQ @ 4K: https://pub-1ee78aacb848486482b20a72b55b3121.r2.dev/IMG_1846_4k.mov
- ProRes 4444 @ 1080p: https://pub-1ee78aacb848486482b20a72b55b3121.r2.dev/prores-transparent-2.mov
- ProRes 422 HQ @ 1080p: https://pub-1ee78aacb848486482b20a72b55b3121.r2.dev/IMG_1846_1080p.mov
- ProRes 422 Proxy @ 1080p: https://pub-1ee78aacb848486482b20a72b55b3121.r2.dev/IMG_1846_1080p_proxy.mov