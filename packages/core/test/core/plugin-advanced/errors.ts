import {
  describe,
  test,
  expect,
  build,
  resolve,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
  expectPluginDiagnostic,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core 플러그인 심화: errors', () => {
  test('plugin_error: thrown string과 hook 이름을 보존', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-throw-'));
    writeFileSync(join(dir, 'index.ts'), 'import "./data.json";');

    const throwPlugin: ZntcPlugin = {
      name: 'throw-on-load',
      setup(build) {
        build.onResolve({ filter: /\.json$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
        build.onLoad({ filter: /\.json$/ }, () => {
          throw 'plain string failure';
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [throwPlugin],
    });
    expectPluginDiagnostic(result, {
      plugin: 'throw-on-load',
      hook: 'load',
      message: 'plain string failure',
      fileIncludes: 'data.json',
    });
    rmSync(dir, { recursive: true, force: true });
  });

  test('플러그인 콜백이 undefined 반환 (null과 동일 처리)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-undef-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');

    const undefPlugin: ZntcPlugin = {
      name: 'undef-return',
      setup(build) {
        build.onLoad({ filter: /\.ts$/ }, () => undefined as any);
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [undefPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('x = 1');
    rmSync(dir, { recursive: true, force: true });
  });
});
