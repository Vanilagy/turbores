import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { defineConfig, build, type Plugin, type Rollup } from 'vite';

const inlineWorkerRE = /\?inline-worker$/;

// Resolves "?inline-worker" imports to the imported file's bundled source code as a string
export const inlinedWorker = (): Plugin => ({
    name: 'inlined-worker',
    enforce: 'pre',

    async resolveId(id, importer) {
        if (!inlineWorkerRE.test(id)) {
            return;
        }

        const resolved = await this.resolve(id.replace(inlineWorkerRE, ''), importer, { skipSelf: true });
        return resolved && resolved.id + '?inline-worker';
    },

    async load(id) {
        if (!inlineWorkerRE.test(id)) {
            return;
        }

        const results = await build({
            configFile: false,
            logLevel: 'warn',
            assetsInclude: ['**/*.wasm'],
            build: {
                write: false,
                // Lib mode keeps vite's preload helper out of the bundle and we use CommonJS so that
                // node:worker_threads works
                lib: {
                    entry: id.replace(inlineWorkerRE, ''),
                    formats: ['cjs'],
                },
                rollupOptions: {
                    external: [/^node:/],
                },
            },
        }) as Rollup.RollupOutput[];

        const chunk = results[0]!.output[0];

        // Rebundle when any file involved in the worker changes
        for (const moduleId of chunk.moduleIds) {
            if (!moduleId.startsWith('\0')) {
                this.addWatchFile(moduleId.split('?')[0]!);
            }
        }

        return `export default ${JSON.stringify(chunk.code)};`;
    },
});

const inlineBinaryRE = /\?inline-binary$/;

// Resolves "?inline-binary" imports to the file's raw bytes as a string, with each byte mapped 1:1 to its code point.
export const inlinedBinary = (): Plugin => {
    let isBuild: boolean;
    const payloads = new Map<string, string>();
    let nextPayloadId = 0;

    return {
        name: 'inlined-binary',
        enforce: 'pre',

        configResolved(config) {
            isBuild = config.command === 'build';
        },

        async resolveId(id, importer) {
            if (!inlineBinaryRE.test(id)) {
                return;
            }

            const resolved = await this.resolve(id.replace(inlineBinaryRE, ''), importer, { skipSelf: true });
            return resolved && resolved.id + '?inline-binary';
        },

        async load(id) {
            if (!inlineBinaryRE.test(id)) {
                return;
            }

            const filePath = id.replace(inlineBinaryRE, '');
            this.addWatchFile(filePath);

            const bytes = await readFile(filePath);

            let string = '';
            for (let i = 0; i < bytes.length; i++) {
                const char = String.fromCharCode(bytes[i]!);

                // Escape everything that could break the string literal
                if (char === '\\' || char === '"' || char === '\'' || char === '`' || char === '$') {
                    string += '\\' + char;
                } else if (char === '\n') {
                    string += '\\n';
                } else if (char === '\r') {
                    string += '\\r';
                } else {
                    string += char;
                }
            }

            if (!isBuild) {
                return `export default "${string}";`;
            }

            // In builds, the minifier would re-escape every control character in the string, bloating it (esbuild
            // offers no way to turn that off). So emit a small placeholder instead, and swap in the real string
            // after the chunks have been rendered, skipping the minifier entirely.
            const placeholder = `__INLINE_BINARY_${nextPayloadId++}__`;
            payloads.set(placeholder, string);

            return `export default "${placeholder}";`;
        },

        generateBundle(options, bundle) {
            for (const item of Object.values(bundle)) {
                if (item.type !== 'chunk') {
                    continue;
                }

                for (const [placeholder, payload] of payloads) {
                    // Function form so that "$" patterns in the payload aren't treated as replacement patterns
                    item.code = item.code.replaceAll(placeholder, payload);
                }
            }
        },
    };
};

export default defineConfig({
    base: './',
    plugins: [inlinedWorker(), inlinedBinary()],
    build: {
        // Lib mode keeps vite's preload helper out of the bundle
        lib: {
            name: 'TurboRes',
            entry: resolve(import.meta.dirname, 'src/index.ts'),
            formats: ['es', 'umd'],
        },
        rollupOptions: {
            external: [/^node:/],
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
