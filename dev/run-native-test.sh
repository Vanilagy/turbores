#!/bin/sh
# Builds the native library and the C smoke test, then runs it against a sample ProRes packet.
#
# Usage: ./dev/run-native-test.sh [prores-file] [reference-gz] [bit-depth] [concurrency]
set -e

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

gcc -O2 dev/test-decode.c \
    -Idev \
    -o build/test-decode \
    -Lbuild "-lturbores-${arch}" -lz

env "${ld_var}=build" ./build/test-decode "$@"
