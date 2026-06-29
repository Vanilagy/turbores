import { defineConfig, mergeConfig, type Plugin } from 'vite';
import baseConfig from './vite.config.js';

const emitHeaders = (): Plugin => ({
    name: 'emit-headers',
    generateBundle() {
        this.emitFile({
            type: 'asset',
            fileName: '_headers',
            source: '/*\n'
                + '  Cross-Origin-Opener-Policy: same-origin\n'
                + '  Cross-Origin-Embedder-Policy: require-corp\n',
        });
    },
});

export default mergeConfig(baseConfig, defineConfig({
    root: './demo',
    plugins: [emitHeaders()],
    build: {
        outDir: '../demo-dist',
        emptyOutDir: true,
        rollupOptions: {
            input: 'demo/index.html',
            output: {
                entryFileNames: 'index.js',
            },
        },
    },
}));
