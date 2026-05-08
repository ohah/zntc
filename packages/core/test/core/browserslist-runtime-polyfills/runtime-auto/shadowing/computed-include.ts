import {
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('@zntc/core runtimePolyfills > auto detection > shadowing > computed include', () => {
  test('runtimePolyfills include covers intentional dynamic computed access', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-computed-include-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          const method = "at";
          globalThis.__VALUE__ = ["x", "y"][method](-1);
        `,
      );

      const autoOnly = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;
      expect(autoOnly).not.toContain('es.array.at');

      const included = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: {
          mode: 'auto',
          targets: ['node 18'],
          include: ['es.array.at'],
        },
      }).outputFiles[0].text;
      expect(included).toContain('es.array.at');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(`Array.prototype.at = undefined;\n${included}`, sandbox);
      expect(sandbox.__VALUE__).toBe('y');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
