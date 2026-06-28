import { defineConfig, mergeConfig } from 'vite';
import baseConfig from './vite.config.js';

export default mergeConfig(baseConfig, defineConfig({
    root: './demo',
    build: {
        outDir: '../demo-dist',
        emptyOutDir: true,
        rollupOptions: {
            input: 'demo/index.html',
        },
    },
}));
