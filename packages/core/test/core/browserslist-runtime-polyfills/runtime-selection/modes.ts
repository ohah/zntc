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

describe('@zntc/core runtimePolyfills > selection and modes > modes', () => {
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
});
