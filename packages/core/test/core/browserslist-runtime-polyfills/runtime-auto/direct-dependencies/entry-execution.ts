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

describe('@zntc/core runtimePolyfills > auto detection > direct dependencies > entry execution', () => {
  test('runtimePolyfills auto: used replaceAll is injected before entry execution', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-auto-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), `globalThis.__RESULT__ = "a-a".replaceAll("a", "b");`);
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
      });
      const code = r.outputFiles[0].text;
      expect(code).toContain('es.string.replace-all');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __RESULT__?: string } = {};
      vm.runInNewContext(`String.prototype.replaceAll = undefined;\n${code}`, sandbox);
      expect(sandbox.__RESULT__).toBe('b-b');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
