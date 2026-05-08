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

describe('@zntc/core 옵션 조합 심화 - buildSync', () => {
  test('buildSync + define + alias + sourcemap 동시', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-combo-all-'));
    writeFileSync(join(dir, 'real.ts'), 'export const val = 42;');
    writeFileSync(
      join(dir, 'index.ts'),
      'import { val } from "@mod";\nconsole.log(val, __VERSION__);',
    );

    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      define: { __VERSION__: '"1.0"' },
      alias: { '@mod': join(dir, 'real.ts') },
      sourcemap: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('42');
    expect(result.outputFiles[0].text).toContain('1.0');
    expect(result.outputFiles.length).toBe(2);
    rmSync(dir, { recursive: true, force: true });
  });
});
