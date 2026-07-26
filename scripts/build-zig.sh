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
else
    mode="Debug"
    [ "$release" = 1 ] && mode="ReleaseFast" # Use fast instead of small, size is still good for fast

    # Pin an explicit feature baseline so builds are reproducible
    case "$target" in
        aarch64-*) cpu="generic+neon" ;;
        x86_64-*) cpu="x86_64_v3" ;;
    esac

    # Artifacts follow each platform's dynamic library naming convention
    case "$target" in
        aarch64-macos) zig_target="aarch64-macos" out="./build/libturbores-aarch64.dylib" ;;
        x86_64-macos) zig_target="x86_64-macos" out="./build/libturbores-x86_64.dylib" ;;
        aarch64-linux) zig_target="aarch64-linux-gnu.2.28" out="./build/libturbores-aarch64.so" ;;
        x86_64-linux) zig_target="x86_64-linux-gnu.2.28" out="./build/libturbores-x86_64.so" ;;
        aarch64-windows) zig_target="aarch64-windows-gnu" out="./build/turbores-aarch64.dll" ;;
        x86_64-windows) zig_target="x86_64-windows-gnu" out="./build/turbores-x86_64.dll" ;;
        *)
            echo "Unsupported target: $target" >&2
            exit 1
            ;;
    esac

    # The internal library name (SONAME/install name) defaults to "libindex", so set it explicitly.
    # Linux also needs libc, otherwise std.Thread.spawn breaks in shared libraries.
    extra_args=""
    case "$target" in
        *-macos) extra_args="-install_name $(basename "$out")" ;;
        *-linux) extra_args="-fsoname=$(basename "$out") -lc" ;;
        # Name the import library after the DLL so the two architectures don't collide
        *-windows) extra_args="-femit-implib=${out%.dll}.lib" ;;
    esac

    zig build-lib \
        -dynamic \
        -target "$zig_target" \
        -mcpu="$cpu" \
        -O $mode \
        -femit-bin="$out" \
        $extra_args \
        ./src/index.zig
fi
