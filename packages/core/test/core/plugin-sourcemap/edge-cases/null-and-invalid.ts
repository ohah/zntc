import {
  build,
  describe,
  expect,
  expectPluginDiagnostic,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core plugin transform sourcemap chain > null and invalid maps', () => {
  test('map: null은 sourcemap 합성을 건너뛰고 빌드를 실패시키지 않음', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-null-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), 'const NULL_MAP_MARKER = 1;\n');

      const plugin: ZntcPlugin = {
        name: 'null-map',
        setup(build) {
          build.onTransform({ filter: /entry\.ts$/ }, (args) => ({
            code: args.code.replace('1', '2'),
            map: null,
          }));
        },
      };

      const result = await build({
        entryPoints: [join(dir, 'entry.ts')],
        sourcemap: true,
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('NULL_MAP_MARKER');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('invalid transform map은 plugin_error diagnostic으로 실패', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-map-invalid-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), 'const INVALID_MAP_MARKER = 1;\n');

      const plugin: ZntcPlugin = {
        name: 'invalid-map',
        setup(build) {
          build.onTransform({ filter: /entry\.ts$/ }, (args) => ({
            code: args.code,
            map: '{ invalid sourcemap json',
          }));
        },
      };

      const result = await build({
        entryPoints: [join(dir, 'entry.ts')],
        sourcemap: true,
        plugins: [plugin],
      });
      expectPluginDiagnostic(result, {
        plugin: 'invalid-map',
        hook: 'transform',
        message: 'Invalid sourcemap',
        fileIncludes: 'entry.ts',
      });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
