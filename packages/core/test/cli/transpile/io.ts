import { describe, existsSync, expect, join, readFileSync, runCli, test } from '../helpers';
import { useTranspileFixture } from './fixture';

describe('CLI: transpile', () => {
  const fixture = useTranspileFixture();

  test('파일 트랜스파일 → stdout', () => {
    const { stdout, exitCode } = runCli([fixture.path('input.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('const x = 1');
    expect(stdout).not.toContain(': number');
  });

  test('stdin 트랜스파일 → stdout', () => {
    const { stdout, exitCode } = runCli(['-'], { input: 'const x: number = 1;' });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('const x = 1');
  });

  test('파일 트랜스파일 → -o 출력', () => {
    const outFile = fixture.path('output.js');
    const { exitCode } = runCli([fixture.path('input.ts'), '-o', outFile]);
    expect(exitCode).toBe(0);
    expect(existsSync(outFile)).toBe(true);
    const content = readFileSync(outFile, 'utf8');
    expect(content).toContain('const x = 1');
  });

  test('파일 트랜스파일 → --outdir 출력', () => {
    const outDir = fixture.path('out');
    const { exitCode } = runCli([fixture.path('input.ts'), '--outdir', outDir]);
    expect(exitCode).toBe(0);
    expect(existsSync(join(outDir, 'input.js'))).toBe(true);
  });

  test('타입/인터페이스만 있는 파일 → 빈 출력', () => {
    const { stdout, exitCode } = runCli([fixture.path('types.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('interface');
    expect(stdout).not.toContain('type Baz');
    expect(stdout).toContain('y = 42');
  });
});
