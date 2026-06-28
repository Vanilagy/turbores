#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 -t <threads> [-a] <video-file>" >&2
    echo "  -t <threads>  number of threads (mandatory)" >&2
    echo "  -a            use hardware acceleration (videotoolbox)" >&2
    exit 1
}

threads=""
hwaccel="none"

while getopts ":t:a" opt; do
    case "$opt" in
        t) threads="$OPTARG" ;;
        a) hwaccel="videotoolbox" ;;
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

get_rtime() {
    local loops="$1"
    ffmpeg -benchmark -threads "$threads" -stream_loop "$loops" -hwaccel "$hwaccel" \
        -i "$video" -f null - 2>&1 \
        | grep -oE 'rtime=[0-9]+\.[0-9]+' \
        | tail -n1 \
        | cut -d= -f2
}

echo "threads=$threads hwaccel=$hwaccel" >&2
echo "Running 11x decode (stream_loop 10)..." >&2
rtime_11=$(get_rtime 10)

echo "Running 1x decode (stream_loop 0)..." >&2
rtime_1=$(get_rtime 0)

avg=$(awk -v a="$rtime_11" -v b="$rtime_1" 'BEGIN { printf "%.4f", (a - b) / 10 }')

echo "rtime (11 runs): ${rtime_11}s" >&2
echo "rtime (1 run):   ${rtime_1}s" >&2
echo "avg per decode:  ${avg}s"