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

describe('@zntc/core runtimePolyfills > auto detection > direct dependencies > local dependencies', () => {
  test('runtimePolyfills auto scans local dependencies and respects modern targets', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-dep-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `import { value } from "./dep"; globalThis.__VALUE__ = value;`,
      );
      writeFileSync(join(dir, 'dep.ts'), `export const value = "a".replaceAll("a", "b");`);

      const oldTarget = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
      }).outputFiles[0].text;
      expect(oldTarget).toContain('es.string.replace-all');

      const modernTarget = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['node 18'] },
      }).outputFiles[0].text;
      expect(modernTarget).not.toContain('es.string.replace-all');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
