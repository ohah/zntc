import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core runtimePolyfills > auto detection > transform plugins', () => {
  test('runtimePolyfills auto detects usage added by transform plugins', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-transform-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), `globalThis.__VALUE__ = "__ORIGINAL__";`);
      const transformPlugin: ZntcPlugin = {
        name: 'runtime-polyfill-transform',
        setup(build) {
          build.onTransform({ filter: /entry\.ts$/ }, () => ({
            code: `globalThis.__VALUE__ = "a-a".replaceAll("a", "b");`,
          }));
        },
      };

      const result = await build({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
        plugins: [transformPlugin],
      });

      expect(result.errors.length).toBe(0);
      const code = result.outputFiles[0].text;
      expect(code).toContain('es.string.replace-all');
      expect(code).not.toContain('__ORIGINAL__');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
