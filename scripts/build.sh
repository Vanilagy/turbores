#!/bin/bash
set -e

rm -rf dist

# Ensure license headers on all source files
tsx scripts/ensure-license-headers.ts

./scripts/build-zig.sh --release
npx vite build

npx tsc -p src
cp build/*.d.ts dist/