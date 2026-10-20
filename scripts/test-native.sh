#!/bin/sh
set -e

cd "$(dirname "$0")/.."

. ./scripts/detect-native-target.sh

./scripts/build-zig.sh "$native_target" --dynamic
./scripts/build-zig.sh "$native_target" --static

mkdir -p build/test-references
for f in tests/public/*.framedata.gz; do
    gunzip -c "$f" > "build/test-references/$(basename "${f%.gz}")"
done

cc -std=c11 -Wall -Wextra -o build/tests-native-dynamic tests/tests-native.c "$native_dynamic_lib"
cc -std=c11 -Wall -Wextra -o build/tests-native-static tests/tests-native.c "$native_static_lib"

echo "Running tests against dynamic library:"
./build/tests-native-dynamic

echo "\nRunning tests against static library:"
./build/tests-native-static
