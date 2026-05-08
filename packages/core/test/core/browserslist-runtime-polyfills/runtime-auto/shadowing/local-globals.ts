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

describe('@zntc/core runtimePolyfills > auto detection > shadowing > local globals', () => {
  test('runtimePolyfills auto ignores shadowed globals and dynamic computed access', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-negative-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          const Map = class LocalMap {};
          const Object = { hasOwn() { return true; } };
          const globalThis = { Set: class LocalSet {} };
          const promiseMethod = "resolve";
          const stringMethod = "replaceAll";
          new Map();
          new globalThis.Set();
          Object.hasOwn({}, "x");
          Promise[promiseMethod](1);
          "a-a"[stringMethod]("a", "b");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).not.toContain('es.map');
      expect(code).not.toContain('es.set');
      expect(code).not.toContain('es.promise');
      expect(code).not.toContain('es.object.has-own');
      expect(code).not.toContain('es.string.replace-all');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
