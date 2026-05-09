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

describe('CLI: zntc.config merge priority > config external', () => {
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
});
