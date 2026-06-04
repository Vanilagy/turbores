#!/bin/sh

mode="Debug"
for arg in "$@"; do
    [ "$arg" = "--release" ] && mode="ReleaseSmall"
done

zig build-exe \
    -target wasm32-freestanding \
    -fno-entry \
    -rdynamic \
    -O $mode \
    -mcpu=generic+bulk_memory+multivalue+nontrapping_fptoint+reference_types+sign_ext+simd128+relaxed_simd \
    -femit-bin=lib.wasm \
    --import-memory \
    decode.zig