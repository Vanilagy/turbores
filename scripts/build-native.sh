#!/bin/sh
# Builds the decoder as a native dynamic library (shared object).
#
# Usage:
#   ./scripts/build-native.sh [--debug | --release] [--x64 | --aarch64] [--mcpu <cpu>]
#
# By default the x86_64 build targets the x86_64_v3 feature level (AVX2 + FMA + BMI), which gives wide SIMD while
# staying a fixed, reproducible target (unlike -mcpu=native, whose output depends on the build host). The aarch64
# build defaults to -mcpu=native to target the full host CPU (assumes a native aarch64 build). Pass --mcpu to set it
# explicitly (e.g. --mcpu x86_64_v4 for AVX-512, --mcpu native for the host CPU, or --mcpu baseline for portable).
#
# The output is written to ./build/libturbores-<arch>.<so|dylib> (dylib on macOS, so on Linux).
set -e

# Build for the host OS: a Mach-O dylib on macOS, an ELF shared object on Linux.
case "$(uname -s)" in
    Darwin) target_os="macos"; lib_ext="dylib" ;;
    *)      target_os="linux-gnu"; lib_ext="so" ;;
esac

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

# Default CPU target: a fixed AVX2+FMA feature level for x86_64 (reproducible, not host-dependent), and the full host
# CPU for aarch64 to squeeze out peak SIMD (assumes a native aarch64 build).
if [ -z "$mcpu" ]; then
    if [ "$arch" = "x86_64" ]; then
        mcpu="x86_64_v4"
    else
        mcpu="native"
    fi
fi

mkdir -p build

# -fsoname is ELF-only; Mach-O records an install name instead, which dyld resolves by leaf via DYLD_LIBRARY_PATH.
if [ "$target_os" = "linux-gnu" ]; then
    set -- -fsoname="libturbores-${arch}.so"
else
    set --
fi

zig build-lib \
    -target "${arch}-${target_os}" \
    -mcpu "$mcpu" \
    -O "$mode" \
    -dynamic \
    -fPIC \
    -fno-single-threaded \
    -lc \
    --name "turbores-${arch}" \
    "$@" \
    -femit-bin="./build/libturbores-${arch}.${lib_ext}" \
    ./src/index.zig

echo "Built ./build/libturbores-${arch}.${lib_ext} ($mode, -mcpu=$mcpu)"
