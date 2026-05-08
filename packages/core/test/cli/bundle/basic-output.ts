import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  tmpdir,
  join,
  runCli,
} from '../helpers';
import { useBundleFixture } from './fixture';

describe('CLI: bundle basic output', () => {
  const fixture = useBundleFixture();

  test('번들 → stdout', () => {
    const { stdout, exitCode } = runCli(['--bundle', fixture.entryPoint()]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('hello');
    expect(stdout).toContain('Hello');
  });

  test('번들 → -o 파일 출력', () => {
    const outFile = join(fixture.dir(), 'bundle.js');
    const { exitCode } = runCli(['--bundle', fixture.entryPoint(), '-o', outFile]);
    expect(exitCode).toBe(0);
    const content = readFileSync(outFile, 'utf8');
    expect(content).toContain('hello');
  });

  test('번들 → --outdir 출력', () => {
    const outDir = join(fixture.dir(), 'dist');
    const { exitCode } = runCli(['--bundle', fixture.entryPoint(), '--outdir', outDir]);
    expect(exitCode).toBe(0);
    expect(existsSync(outDir)).toBe(true);
  });

  test('번들 --allow-overwrite 미지정 시 입력=출력 차단', () => {
    const overwriteDir = mkdtempSync(join(tmpdir(), 'zntc-cli-bundle-overwrite-'));
    try {
      const file = join(overwriteDir, 'entry.js');
      writeFileSync(file, 'export const value = 1;\n');
      const { exitCode, stderr } = runCli(['--bundle', file, '-o', file]);
      expect(exitCode).toBe(1);
      expect(stderr).toContain('would overwrite input file');
    } finally {
      rmSync(overwriteDir, { recursive: true, force: true });
    }
  });

  test('번들 --allow-overwrite 지정 시 입력=출력 허용', () => {
    const overwriteDir = mkdtempSync(join(tmpdir(), 'zntc-cli-bundle-overwrite-'));
    try {
      const file = join(overwriteDir, 'entry.js');
      writeFileSync(file, 'export const value = 1;\n');
      const { exitCode, stderr } = runCli(['--bundle', file, '-o', file, '--allow-overwrite']);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('would overwrite');
      expect(readFileSync(file, 'utf8')).toContain('value');
    } finally {
      rmSync(overwriteDir, { recursive: true, force: true });
    }
  });

  test('번들 + --minify', () => {
    const normal = runCli(['--bundle', fixture.entryPoint()]);
    const minified = runCli(['--bundle', fixture.entryPoint(), '--minify']);
    expect(minified.exitCode).toBe(0);
    expect(minified.stdout.length).toBeLessThan(normal.stdout.length);
  });
});
