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
} from './helpers';

describe('@zntc/core runtimePolyfills > selection and modes', () => {
  test('runtimePolyfills include is forced and exclude removes final selected modules', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-include-exclude-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          const value = ["a"].at(0);
          globalThis.__VALUE__ = "a-a".replaceAll("a", value ?? "b");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: {
          mode: 'auto',
          targets: ['ios_saf 12'],
          include: ['es.promise'],
          exclude: ['es.string.replace-all'],
        },
      }).outputFiles[0].text;

      expect(code).toContain('es.array.at');
      expect(code).toContain('es.promise');
      expect(code).not.toContain('es.string.replace-all');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills entry and off modes stay separate from usage collection', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-modes-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), `globalThis.__VALUE__ = "a".replaceAll("a", "b");`);

      const entryMode = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'entry', targets: ['safari 5'] },
      }).outputFiles[0].text;
      expect(entryMode).toContain('es.map');
      expect(entryMode).toContain('es.promise');
      expect(entryMode).toContain('es.string.replace-all');

      const offMode = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: 'off',
      }).outputFiles[0].text;
      expect(offMode).not.toContain('es.string.replace-all');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

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

  test('runtimePolyfills rejects compact target shorthand through build API', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-shorthand-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), `"a".replaceAll("a", "b");`);
      expect(() =>
        buildSync({
          entryPoints: [join(dir, 'entry.ts')],
          runtimePolyfills: { mode: 'auto', targets: ['ios12'] },
        }),
      ).toThrow('Compact runtime target shorthands');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
