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

describe('@zntc/core runtimePolyfills > auto detection > global built-ins > expanded built-ins', () => {
  test('runtimePolyfills auto injects expanded core-js built-ins', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-expanded-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          const key = {};
          const weak = new WeakMap();
          weak.set(key, 7);
          globalThis.__VALUE__ = [
            Object.values({ label: "value" })[0],
            "7".padStart(2, "0"),
            Math.trunc(1.8),
            Reflect.ownKeys({ own: true })[0],
            [1, 2, 3].findLast((value) => value < 3),
            typeof Symbol === "function",
            weak.get(key),
          ].join("|");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).toContain('es.object.values');
      expect(code).toContain('es.string.pad-start');
      expect(code).toContain('es.math.trunc');
      expect(code).toContain('es.reflect.own-keys');
      expect(code).toContain('es.array.find-last');
      expect(code).toContain('es.weak-map');
      expect(code).toContain('es.symbol');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(
        `
          Object.values = undefined;
          String.prototype.padStart = undefined;
          Math.trunc = undefined;
          Reflect.ownKeys = undefined;
          Array.prototype.findLast = undefined;
          globalThis.WeakMap = undefined;
          globalThis.Symbol = undefined;
          ${code}
        `,
        sandbox,
      );
      expect(sandbox.__VALUE__).toBe('value|07|1|own|2|true|7');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
