#!/bin/sh
# Builds the decoder as a native dynamic library (shared object).
#
# Usage:
#   ./scripts/build-native.sh [--debug | --release] [--x64 | --aarch64] [--mcpu <cpu>]
#
# By default the x86_64 build targets the x86_64_v3 feature level (AVX2 + FMA + BMI), which gives wide SIMD while
# staying a fixed, reproducible target (unlike -mcpu=native, whose output depends on the build host). The aarch64
# build is a cross-compile, so it uses a portable baseline unless overridden. Pass --mcpu to set it explicitly
# (e.g. --mcpu x86_64_v4 for AVX-512, --mcpu native for the host CPU, or --mcpu baseline for portable SSE2).
#
# The output is written to ./build/libturbores-<arch>.so
set -e

mode="ReleaseFast"
arch="x86_64"
mcpu=""

prev=""
for arg in "$@"; do
    if [ "$prev" = "--mcpu" ]; then mcpu="$arg"; prev=""; continue; fi
    case "$arg" in
        --debug)            mode="Debug" ;;
        --release)          mode="ReleaseFast" ;;
        --x64|--x86_64)     arch="x86_64" ;;
        --aarch64|--arm64)  arch="aarch64" ;;
        --mcpu)             prev="--mcpu" ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# Default CPU target: a fixed AVX2+FMA feature level for x86_64 (reproducible, not host-dependent), portable baseline
# for the aarch64 cross-build.
if [ -z "$mcpu" ]; then
    if [ "$arch" = "x86_64" ]; then
        mcpu="x86_64_v4"
    else
        mcpu="baseline"
    fi
fi

mkdir -p build

zig build-lib \
    -target "${arch}-linux-gnu" \
    -mcpu "$mcpu" \
    -O "$mode" \
    -dynamic \
    -fPIC \
    -fno-single-threaded \
    -lc \
    --name "turbores-${arch}" \
    -fsoname="libturbores-${arch}.so" \
    -femit-bin="./build/libturbores-${arch}.so" \
    ./src/index.zig

echo "Built ./build/libturbores-${arch}.so ($mode, -mcpu=$mcpu)"
