#!/bin/sh
# Builds the native library and the C smoke test, then runs it against a sample ProRes packet.
#
# Usage: ./dev/run-native-test.sh [prores-file] [reference-gz] [bit-depth] [concurrency]
set -e

cd "$(dirname "$0")/.."

arch="x86_64"

./scripts/build-native.sh --release "--${arch}"

gcc -O2 dev/test-decode.c \
    -Idev \
    -o build/test-decode \
    -Lbuild "-lturbores-${arch}" -lz

LD_LIBRARY_PATH=build ./build/test-decode "$@"
