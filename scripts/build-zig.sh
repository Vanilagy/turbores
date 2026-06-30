#!/bin/sh
set -e

mode="Debug"
for arg in "$@"; do
    [ "$arg" = "--release" ] && mode="ReleaseSmall"
done

mkdir -p build

zig build-exe \
    -target wasm32-freestanding \
    -fno-entry \
    -rdynamic \
    -O $mode \
    -mcpu=generic+atomics+bulk_memory+multivalue+nontrapping_fptoint+reference_types+sign_ext+simd128+relaxed_simd \
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

echo "Built ./build/lib.wasm ($mode)"