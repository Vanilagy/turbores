#!/bin/sh
# Builds the release native library and the frame-parallel decode benchmark (bench-decode-2), then runs it.
#
# Unlike run-native-bench.sh (which uses turbores' built-in intra-frame threading), this benchmark mimics FFmpeg's
# frame-threading: `concurrency` independent synchronous decoders on `concurrency` OS threads, with packets
# round-robin-assigned to them.
#
# Usage: ./dev/run-native-bench-2.sh <video-file> <concurrency> [repeats]
#
# Example (concurrency = number of logical cores, 10 repeats):
#   ./dev/run-native-bench-2.sh here.mov "$(nproc)"
set -e

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <video-file> <concurrency> [repeats]" >&2
    echo "  e.g. $0 here.mov \"\$(nproc)\"" >&2
    exit 2
fi

cd "$(dirname "$0")/.."

arch="x86_64"

./scripts/build-native.sh --release "--${arch}"

gcc -O3 -pthread dev/bench-decode-2.c \
    -Idev \
    -o build/bench-decode-2 \
    -Lbuild "-lturbores-${arch}" \
    $(pkg-config --cflags --libs libavformat libavcodec libavutil)

LD_LIBRARY_PATH=build ./build/bench-decode-2 "$@"
