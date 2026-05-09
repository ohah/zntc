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

describe('CLI: zntc.config BuildOptions > external packages', () => {
  test('zntc.config.json 의 external 배열이 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-external-'));
    writeFileSync(join(dir, 'entry.ts'), 'import * as fs from "node:fs";\nconsole.log(fs);');
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ external: ['node:fs'] }));
    const { stdout, stderr, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toMatch(/node:fs|require.*fs/);
    expect(stderr).not.toContain('error');
    rmSync(dir, { recursive: true, force: true });
  });

  test('zntc.config.json 의 packagesExternal 이 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-packages-external-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        'import React from "react";\nimport { local } from "./local";\nconsole.log(React, local);',
      );
      writeFileSync(join(dir, 'local.ts'), "export const local = 'CONFIG_LOCAL_INCLUDED';");
      writeFileSync(
        join(dir, 'zntc.config.json'),
        JSON.stringify({ entryPoints: ['./entry.ts'], packagesExternal: true, format: 'esm' }),
      );
      const { stdout, stderr, exitCode } = runCli(['--bundle'], { cwd: dir });
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('error');
      expect(stdout).toContain('"react"');
      expect(stdout).toContain('CONFIG_LOCAL_INCLUDED');
      expect(stdout).not.toContain('from "./local"');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
