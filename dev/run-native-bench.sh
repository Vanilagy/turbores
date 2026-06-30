#!/bin/sh
# Builds the release native library and the decode benchmark, then runs it.
#
# The benchmark demuxes every ProRes packet from a video file (via FFmpeg's libavformat) and decodes the whole
# sequence through turbores, repeating the full-file decode several times.
#
# Usage: ./dev/run-native-bench.sh <video-file> <concurrency> [repeats]
#
# Example (concurrency = number of logical cores, 10 repeats):
#   ./dev/run-native-bench.sh prores-buck-bunny.mov "$(nproc)"
set -e

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <video-file> <concurrency> [repeats]" >&2
    echo "  e.g. $0 prores-buck-bunny.mov \"\$(nproc)\"" >&2
    exit 2
fi

cd "$(dirname "$0")/.."

# Match the build to the host: native arch, and the right runtime loader path. The linker finds the right
# library extension (.dylib / .so) via -l on its own.
case "$(uname -m)" in
    arm64|aarch64) arch="aarch64" ;;
    *)             arch="x86_64" ;;
esac
case "$(uname -s)" in
    Darwin) ld_var="DYLD_LIBRARY_PATH" ;;
    *)      ld_var="LD_LIBRARY_PATH" ;;
esac

./scripts/build-native.sh --release "--${arch}"

gcc -O3 dev/bench-decode.c \
    -Idev \
    -o build/bench-decode \
    -Lbuild "-lturbores-${arch}"

env "${ld_var}=build" ./build/bench-decode "$@"
