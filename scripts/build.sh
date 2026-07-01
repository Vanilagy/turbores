#!/bin/bash
set -e

rm -rf dist

# Ensure license headers on all source files
tsx scripts/ensure-license-headers.ts

./scripts/build-zig.sh --release
npx vite build

npx tsc -p src
npx api-extractor run

npm run check-docblocks

# Appends stuff to the declaration file to register the global variable this library exposes
echo 'export as namespace TurboRes;' >> dist/turbores.d.ts