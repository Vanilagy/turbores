#!/bin/sh
set -e

cd "$(dirname "$0")/.."

./scripts/build-zig.sh aarch64-macos

mkdir -p build/test-references
for f in tests/public/*.framedata.gz; do
    gunzip -c "$f" > "build/test-references/$(basename "${f%.gz}")"
done

cc -std=c11 -Wall -Wextra -o build/tests-native tests/tests-native.c build/libturbores.dylib

DYLD_LIBRARY_PATH=build ./build/tests-native
