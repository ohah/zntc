import {
  describe,
  existsSync,
  expect,
  join,
  mkdtempSync,
  readFileSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';
import { useTranspileFixture } from './fixture';

describe('CLI: transpile', () => {
  const fixture = useTranspileFixture();

  test('--minify 옵션', () => {
    const normal = runCli([fixture.path('input.ts')]);
    const minified = runCli([fixture.path('input.ts'), '--minify']);
    expect(minified.exitCode).toBe(0);
    expect(minified.stdout.length).toBeLessThan(normal.stdout.length);
  });

  test('--sourcemap 옵션 + -o', () => {
    const outFile = fixture.path('with-map.js');
    const { exitCode } = runCli([fixture.path('input.ts'), '--sourcemap', '-o', outFile]);
    expect(exitCode).toBe(0);
    expect(existsSync(outFile)).toBe(true);
    expect(existsSync(outFile + '.map')).toBe(true);
    const map = JSON.parse(readFileSync(outFile + '.map', 'utf8'));
    expect(map.version).toBe(3);
  });

  test('--format=cjs', () => {
    const { stdout, exitCode } = runCli([fixture.path('input.ts'), '--format=cjs']);
    expect(exitCode).toBe(0);
    // 트랜스파일 모드에서 CJS는 코드 자체를 변환
    expect(stdout).toContain('x = 1');
  });

  test('--flow 옵션', () => {
    const flowDir = mkdtempSync(join(tmpdir(), 'zntc-cli-flow-'));
    writeFileSync(
      join(flowDir, 'flow.js'),
      '// @flow\nfunction foo(x: string): number { return x.length; }',
    );
    const { stdout, exitCode } = runCli([join(flowDir, 'flow.js'), '--flow']);
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain(': string');
    expect(stdout).not.toContain(': number');
    rmSync(flowDir, { recursive: true, force: true });
  });

  test('--drop=console', () => {
    const { stdout, exitCode } = runCli([fixture.path('input.ts'), '--drop=console']);
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('console.log');
  });
});
