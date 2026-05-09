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

describe('@zntc/core runtimePolyfills > selection and modes > invalid target', () => {
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
