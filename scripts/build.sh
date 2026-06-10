#!/bin/bash
set -e

rm -rf dist

./scripts/build-zig.sh --release
npx vite build

npx tsc
cp build/*.d.ts dist/