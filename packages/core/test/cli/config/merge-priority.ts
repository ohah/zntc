import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from '../helpers';

describe('CLI: zntc.config merge priority', () => {
  test('CLI 가 config 를 override (CLI > config 우선순위)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-override-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('cli_wins');");
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ format: 'iife', globalName: 'CFG_NAME' }),
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', '--global-name=CLI_NAME', join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('CLI_NAME');
    expect(stdout).not.toContain('CFG_NAME');
    rmSync(dir, { recursive: true, force: true });
  });

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

  test('config 의 external 배열 — CLI external 빈 상태면 config 사용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-external-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `import * as path from "node:path";
       import * as fs from "node:fs";
       console.log(path, fs);`,
    );
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ external: ['node:path', 'node:fs'] }),
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toMatch(/node:path/);
    expect(stdout).toMatch(/node:fs/);
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig + config + CLI 3-way 우선순위: CLI > config > tsconfig', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-3way-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { jsx: 'preserve' } }),
    );
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ jsx: 'automatic' }));
    writeFileSync(join(dir, 'src', 'App.tsx'), 'export default () => <div>Hello</div>;');
    const { stdout, exitCode } = runCli(
      ['--bundle', '--jsx=transform', join(dir, 'src', 'App.tsx')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('React.createElement');
    expect(stdout).not.toContain('jsx-runtime');
    expect(stdout).not.toContain('<div>');
    rmSync(dir, { recursive: true, force: true });
  });
});
