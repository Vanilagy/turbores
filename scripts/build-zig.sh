#!/bin/sh
set -e

release=0
target="wasm32-freestanding"
for arg in "$@"; do
    case "$arg" in
        --release) release=1 ;;
        *) target="$arg" ;;
    esac
done

mkdir -p build

if [ "$target" = "wasm32-freestanding" ]; then
    mode="Debug"
    [ "$release" = 1 ] && mode="ReleaseSmall"

    zig build-exe \
        -target wasm32-freestanding \
        -fno-entry \
        -rdynamic \
        -O $mode \
        -mcpu=generic+atomics+bulk_memory+multivalue+nontrapping_fptoint+reference_types+sign_ext+simd128 \
        -femit-bin=./build/lib.wasm \
        -fno-single-threaded \
        --import-memory \
        --shared-memory \
        --max-memory=$((65536 * 65536)) \
        --export=__stack_pointer \
        --export=__tls_base \
        --export=__tls_size \
        --export=__tls_align \
        --export=__wasm_init_tls \
        ./src/index.zig
elif [ "$target" = "aarch64-macos" ]; then
    mode="Debug"
    [ "$release" = 1 ] && mode="ReleaseFast" # Use fast instead of small, size is still good for fast

    zig build-lib \
        -dynamic \
        -target aarch64-macos \
        -mcpu=generic+neon \
        -O $mode \
        -femit-bin=./build/libturbores.dylib \
        ./src/index.zig
else
    echo "Unsupported target: $target" >&2
    exit 1
fi
