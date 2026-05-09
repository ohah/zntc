import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  rmSync,
  tmpdir,
  join,
  runCli,
} from '../../helpers';

describe('CLI: zntc.config merge priority > object merges', () => {
  test('config 의 alias 객체 머지 — CLI alias 가 키 단위로 override', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-alias-'));
    writeFileSync(join(dir, 'real-a.ts'), "export const tag = 'CONFIG_ALIAS_A';");
    writeFileSync(join(dir, 'real-b.ts'), "export const tag = 'CLI_ALIAS_B';");
    writeFileSync(
      join(dir, 'entry.ts'),
      `import { tag as a } from "@a";
       import { tag as b } from "@b";
       console.log(a, b);`,
    );
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({
        alias: {
          '@a': join(dir, 'real-a.ts'),
          '@b': join(dir, 'should-be-overridden.ts'),
        },
      }),
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', `--alias:@b=${join(dir, 'real-b.ts')}`, join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('CONFIG_ALIAS_A');
    expect(stdout).toContain('CLI_ALIAS_B');
    rmSync(dir, { recursive: true, force: true });
  });

  test('config 의 define 객체 + CLI define 머지 — 키 단위 override', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-define-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `console.log(__VER__);
       console.log(__BUILD__);`,
    );
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({
        define: { __VER__: '"v_from_config"', __BUILD__: '"build_from_config"' },
      }),
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', '--define:__BUILD__="build_from_cli"', join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('v_from_config');
    expect(stdout).toContain('build_from_cli');
    rmSync(dir, { recursive: true, force: true });
  });
});
