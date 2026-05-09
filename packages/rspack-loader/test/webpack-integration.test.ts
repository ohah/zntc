import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const __dirname = dirname(fileURLToPath(import.meta.url));
const loaderEntry = resolve(__dirname, '../src/index.ts');

let workDir: string;

beforeEach(() => {
  workDir = mkdtempSync(join(tmpdir(), 'zntc-webpack-loader-'));
});

afterEach(() => {
  rmSync(workDir, { recursive: true, force: true });
});

function writeFixture(rel: string, content: string): string {
  const abs = join(workDir, rel);
  mkdirSync(dirname(abs), { recursive: true });
  writeFileSync(abs, content);
  return abs;
}

describe('@zntc/rspack-loader — webpack 5 programmatic integration', () => {
  test('webpack 빌드에서 동일 loader 가 정상 동작 (rspack/webpack 양쪽 호환)', async () => {
    const entry = writeFixture('entry.ts', 'const x: number = 41 + 1;\nexport default x;\n');
    const outDir = join(workDir, 'dist');
    mkdirSync(outDir, { recursive: true });

    const webpack = ((await import('webpack')) as { default: unknown }).default as (
      config: unknown,
      cb: (err: Error | null, stats?: unknown) => void,
    ) => unknown;

    const compile = promisify<unknown, unknown>(webpack as never);
    const stats = (await compile({
      mode: 'development',
      devtool: false,
      target: 'node',
      entry,
      output: {
        path: outDir,
        filename: 'bundle.js',
        library: { type: 'commonjs2' },
      },
      module: {
        rules: [
          {
            test: /\.ts$/,
            loader: loaderEntry,
            options: { transpileOptions: { target: 'es2022' } },
          },
        ],
      },
      stats: 'errors-only',
    })) as { hasErrors(): boolean; toJson(opts: unknown): { errors: unknown[] } };

    expect(stats.hasErrors()).toBe(false);
    const bundle = readFileSync(join(outDir, 'bundle.js'), 'utf8');
    expect(bundle).toContain('41 + 1');
    expect(bundle).not.toContain(': number');
  }, 30000);
});
