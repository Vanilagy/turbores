#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 -t <threads> <video-file>" >&2
    echo "  -t <threads>  number of threads (mandatory, 0 = synchronous)" >&2
    exit 1
}

threads=""

while getopts ":t:" opt; do
    case "$opt" in
        t) threads="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

if [ -z "$threads" ]; then
    echo "error: -t <threads> is required" >&2
    usage
fi

if [ $# -ne 1 ]; then
    usage
fi

video="$1"

if [ ! -f "$video" ]; then
    echo "error: file not found: $video" >&2
    exit 1
fi

# The benchmark runs from the repo root, so resolve the video path first
video="$(cd "$(dirname "$video")" && pwd)/$(basename "$video")"
cd "$(dirname "$0")/.."

. ./scripts/detect-native-target.sh

./scripts/build-zig.sh "$native_target" --release

cc -std=c11 -O3 -Wall -Wextra \
    -o build/benchmark-turbores-native \
    benchmark/benchmark-turbores-native.c \
    "$native_lib"

./build/benchmark-turbores-native "$video" "$threads"
