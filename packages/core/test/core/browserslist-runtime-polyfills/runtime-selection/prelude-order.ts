import {
  describe,
  test,
  expect,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from '../helpers';

describe('@zntc/core runtimePolyfills > selection and modes > prelude order', () => {
  test('runtimePolyfills prelude runs after manual polyfills and before runBeforeMain', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-order-'));
    try {
      const polyfillFile = join(dir, 'manual-polyfill.js');
      const initFile = join(dir, 'init.ts');
      writeFileSync(
        polyfillFile,
        `
          globalThis.__ORDER__ = ["polyfill"];
          String.prototype.replaceAll = undefined;
        `,
      );
      writeFileSync(
        initFile,
        `globalThis.__ORDER__.push("runBeforeMain:" + "a".replaceAll("a", "b"));`,
      );
      writeFileSync(
        join(dir, 'entry.ts'),
        `globalThis.__ORDER__.push("entry:" + "a".replaceAll("a", "c"));`,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        polyfills: [polyfillFile],
        runBeforeMain: [initFile],
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
      }).outputFiles[0].text;

      expect(code).toContain('es.string.replace-all');
      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __ORDER__?: string[] } = {};
      vm.runInNewContext(code, sandbox);
      expect(sandbox.__ORDER__).toEqual(['polyfill', 'runBeforeMain:b', 'entry:c']);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
