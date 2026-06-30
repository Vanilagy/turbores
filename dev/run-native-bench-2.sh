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

gcc -O3 -pthread dev/bench-decode-2.c \
    -Idev \
    -o build/bench-decode-2 \
    -Lbuild "-lturbores-${arch}"

env "${ld_var}=build" ./build/bench-decode-2 "$@"
