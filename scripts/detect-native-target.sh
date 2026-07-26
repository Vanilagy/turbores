#!/bin/sh
# Detects the current machine's OS/architecture. Meant to be sourced from the repo root; sets:
#   native_target      - the build-zig.sh target matching this machine
#   native_dynamic_lib - path to the dynamic library artifact (--dynamic) for that target
#   native_static_lib  - path to the static library artifact (--static) for that target
# Also puts ./build on the dynamic library search path so freshly built binaries can run.

case "$(uname -s)" in
    Darwin) native_os="macos" ;;
    Linux) native_os="linux" ;;
    MINGW* | MSYS* | CYGWIN*) native_os="windows" ;;
    *)
        echo "Unsupported OS: $(uname -s)" >&2
        exit 1
        ;;
esac

case "$(uname -m)" in
    arm64 | aarch64) native_arch="aarch64" ;;
    x86_64 | amd64) native_arch="x86_64" ;;
    *)
        echo "Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

native_target="$native_arch-$native_os"

case "$native_os" in
    macos)
        native_dynamic_lib="build/libturbores-macos-$native_arch.dylib"
        native_static_lib="build/libturbores-macos-$native_arch.a"
        export DYLD_LIBRARY_PATH="build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
        ;;
    linux)
        native_dynamic_lib="build/libturbores-linux-$native_arch.so"
        native_static_lib="build/libturbores-linux-$native_arch.a"
        export LD_LIBRARY_PATH="build${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        ;;
    windows)
        native_dynamic_lib="build/turbores-windows-$native_arch.dll"
        native_static_lib="build/turbores-windows-$native_arch-static.lib"
        export PATH="$PWD/build:$PATH"
        ;;
esac
