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

describe('@zntc/core runtimePolyfills > selection and modes > include/exclude', () => {
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
});
