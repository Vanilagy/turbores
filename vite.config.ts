import { resolve } from 'node:path';
import { defineConfig } from 'vite';

export default defineConfig({
    base: './',
    build: {
        // No lib mode beacuse we don't wanna inline the WASM
        assetsInlineLimit: 0,
        rollupOptions: {
            input: resolve(import.meta.dirname, 'src/index.ts'),
            // index.ts only re-exports, so keep its exports instead of treeshaking them away
            preserveEntrySignatures: 'strict',
            external: [/^node:/],
            output: {
                format: 'es',
                entryFileNames: '[name].js',
                assetFileNames: '[name].[ext]',
            },
        },
    },
    worker: {
        format: 'es',
        rollupOptions: {
            external: [/^node:/],
            output: {
                entryFileNames: '[name].js',
                assetFileNames: '[name].[ext]',
            },
        },
    },
    server: {
        hmr: false,
        headers: {
            'Cross-Origin-Opener-Policy': 'same-origin',
            'Cross-Origin-Embedder-Policy': 'require-corp',
        },
        allowedHosts: true,
    },
});
