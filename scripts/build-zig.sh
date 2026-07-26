#!/bin/sh
set -e

release=0
linkage=""
target="wasm32-freestanding"
for arg in "$@"; do
    case "$arg" in
        --release) release=1 ;;
        --dynamic) linkage="dynamic" ;;
        --static) linkage="static" ;;
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
    if [ -z "$linkage" ]; then
        echo "Specify --dynamic or --static for native targets" >&2
        exit 1
    fi

    mode="Debug"
    [ "$release" = 1 ] && mode="ReleaseFast" # Use fast instead of small, size is still good for fast

    # Pin an explicit feature baseline so builds are reproducible
    case "$target" in
        aarch64-*) cpu="generic+neon" ;;
        x86_64-*) cpu="x86_64_v3" ;;
    esac

    case "$target" in
        aarch64-macos) zig_target="aarch64-macos" ;;
        x86_64-macos) zig_target="x86_64-macos" ;;
        aarch64-linux) zig_target="aarch64-linux-gnu.2.28" ;;
        x86_64-linux) zig_target="x86_64-linux-gnu.2.28" ;;
        aarch64-windows) zig_target="aarch64-windows-gnu" ;;
        x86_64-windows) zig_target="x86_64-windows-gnu" ;;
        *)
            echo "Unsupported target: $target" >&2
            exit 1
            ;;
    esac

    arch="${target%%-*}"
    os="${target#*-}"

    # Artifacts follow each platform's library naming convention
    case "$os" in
        windows) name="turbores-$os-$arch" ;;
        *) name="libturbores-$os-$arch" ;;
    esac

    extra_args=""
    if [ "$linkage" = "dynamic" ]; then
        # The internal library name (SONAME/install name) defaults to "libindex", so set it explicitly
        case "$os" in
            macos) out="./build/$name.dylib" extra_args="-install_name $name.dylib" ;;
            linux) out="./build/$name.so" extra_args="-fsoname=$name.so" ;;
            # "-dynamic"/"-static" suffixes keep the two .lib flavors apart
            windows) out="./build/$name.dll" extra_args="-femit-implib=./build/$name-dynamic.lib" ;;
        esac
        extra_args="$extra_args -dynamic"
    else
        case "$os" in
            windows) out="./build/$name-static.lib" ;;
            *) out="./build/$name.a" ;;
        esac
        # Bundle compiler-rt so consumers' toolchains don't need to provide its symbols
        extra_args="-fcompiler-rt"
    fi

    case "$target" in
        # Linux needs libc, otherwise std.Thread.spawn breaks outside of Zig executables
        *-linux) extra_args="$extra_args -lc" ;;
    esac

    zig build-lib \
        -target "$zig_target" \
        -mcpu="$cpu" \
        -O $mode \
        -femit-bin="$out" \
        $extra_args \
        ./src/index.zig
fi
