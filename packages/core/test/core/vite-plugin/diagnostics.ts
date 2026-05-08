import {
  build,
  describe,
  expectPluginDiagnostic,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  vitePlugin,
  writeFileSync,
} from './helpers';
import type { RollupPlugin } from './helpers';

describe('vitePlugin 어댑터 - plugin_error diagnostic', () => {
  test('plugin_error: vitePlugin.resolveId sync throw가 diagnostic으로 노출됨', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-resolve-error-'));
    writeFileSync(join(dir, 'entry.ts'), 'import "virtual:boom";');

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'vite-resolve-fail',
          resolveId(source) {
            if (source === 'virtual:boom') throw new Error('resolve exploded');
          },
        }),
      ],
    });
    expectPluginDiagnostic(result, {
      plugin: 'vite-resolve-fail',
      hook: 'resolveId',
      message: 'resolve exploded',
      fileIncludes: 'entry.ts',
    });
    rmSync(dir, { recursive: true, force: true });
  });

  test('plugin_error: vitePlugin.load의 this.error가 RollupError-like location을 보존', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-this-error-'));
    const virtualId = join(dir, 'virtual.ts');
    writeFileSync(join(dir, 'entry.ts'), 'import "./virtual";');

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'vite-this-error',
          resolveId(source) {
            if (source === './virtual') return virtualId;
          },
          load(id) {
            if (id === virtualId) {
              this.error({
                message: 'rollup context failed',
                id,
                loc: { file: id, line: 7, column: 3 },
              });
            }
          },
        } as RollupPlugin),
      ],
    });
    expectPluginDiagnostic(result, {
      plugin: 'vite-this-error',
      hook: 'load',
      message: 'rollup context failed',
      fileIncludes: 'virtual.ts',
      textIncludes: '7:3',
    });
    rmSync(dir, { recursive: true, force: true });
  });

  test('plugin_error: vitePlugin.transform async reject가 diagnostic으로 노출됨', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-transform-error-'));
    writeFileSync(join(dir, 'entry.ts'), 'console.log("vite transform");');

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'vite-transform-fail',
          async transform() {
            throw new Error('vite transform rejected');
          },
        }),
      ],
    });
    expectPluginDiagnostic(result, {
      plugin: 'vite-transform-fail',
      hook: 'transform',
      message: 'vite transform rejected',
      fileIncludes: 'entry.ts',
    });
    rmSync(dir, { recursive: true, force: true });
  });
});
