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

describe('@zntc/core runtimePolyfills > auto detection > global built-ins > globalThis', () => {
  test('runtimePolyfills auto detects explicit globalThis runtime API usage', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-globalthis-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          globalThis.__RESULT__ = [
            typeof globalThis.Map,
            typeof globalThis.Set,
            typeof globalThis.Promise.resolve,
            typeof globalThis.structuredClone,
            globalThis.Object.hasOwn({ ok: true }, "ok"),
          ].join("|");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).toContain('es.map');
      expect(code).toContain('es.set');
      expect(code).toContain('es.promise');
      expect(code).toContain('web.structured-clone');
      expect(code).toContain('es.object.has-own');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __RESULT__?: string } = {};
      vm.runInNewContext(
        `
          globalThis.Map = undefined;
          globalThis.Set = undefined;
          globalThis.Promise = undefined;
          globalThis.structuredClone = undefined;
          globalThis.Object.hasOwn = undefined;
          ${code}
        `,
        sandbox,
      );
      expect(sandbox.__RESULT__).toBe('function|function|function|function|true');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
