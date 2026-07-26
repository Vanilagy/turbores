#!/bin/sh
set -e

cd "$(dirname "$0")/.."

. ./scripts/detect-native-target.sh

./scripts/build-zig.sh "$native_target"

mkdir -p build/test-references
for f in tests/public/*.framedata.gz; do
    gunzip -c "$f" > "build/test-references/$(basename "${f%.gz}")"
done

cc -std=c11 -Wall -Wextra -o build/tests-native tests/tests-native.c "$native_lib"

./build/tests-native
