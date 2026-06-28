import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';
import stylistic from '@stylistic/eslint-plugin';

export default tseslint.config(
    eslint.configs.recommended,
    tseslint.configs.recommendedTypeChecked,
    {
        languageOptions: {
            parserOptions: {
                projectService: true,
                tsconfigRootDir: import.meta.dirname,
            },
        },
    },
    stylistic.configs.customize({
        indent: 4,
        quotes: 'single',
        semi: true,
        braceStyle: '1tbs',
    }),
    {
        rules: {
            '@stylistic/max-len': ['error', {
                code: 120,
            }],
            'curly': ['error', 'multi-line'],
            'eqeqeq': ['error', 'always', { null: 'ignore' }],
            '@typescript-eslint/no-empty-object-type': 'off',
            '@typescript-eslint/require-await': 'off',
            '@stylistic/yield-star-spacing': ['error', { before: false, after: true }],
            '@typescript-eslint/no-unsafe-enum-comparison': 'off',
            '@typescript-eslint/no-unsafe-unary-minus': 'off',
            '@typescript-eslint/no-deprecated': 'error',
            '@typescript-eslint/consistent-type-exports': 'error',
        },
    },
    {
        ignores: [
            'dist',
            'build',
            'eslint.config.mjs',
            'dev',
            'demo-dist',
        ],
    },
);
