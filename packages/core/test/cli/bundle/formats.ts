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
} from '../helpers';
import { useBundleFixture } from './fixture';

describe('CLI: bundle format and wrappers', () => {
  const fixture = useBundleFixture();

  test('번들 + --format=cjs', () => {
    const { stdout, exitCode } = runCli(['--bundle', fixture.entryPoint(), '--format=cjs']);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('use strict');
  });

  test('번들 + --intro/--outro wrapper 내부 텍스트 삽입', () => {
    const { stdout, stderr, exitCode } = runCli([
      '--bundle',
      fixture.entryPoint(),
      "--intro=console.log('intro');",
      "--outro=console.log('outro');",
    ]);
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('unknown option');
    expect(stdout).toContain("console.log('intro');");
    expect(stdout).toContain("console.log('outro');");
    expect(stdout.indexOf("console.log('intro');")).toBeLessThan(stdout.indexOf('Hello'));
    expect(stdout.indexOf('Hello')).toBeLessThan(stdout.indexOf("console.log('outro');"));
  });

  test('번들 + --global:SPEC=NAME maps IIFE external globals', () => {
    const globalDir = mkdtempSync(join(tmpdir(), 'zntc-cli-globals-'));
    try {
      writeFileSync(
        join(globalDir, 'entry.ts'),
        "import { useState } from 'react'; console.log(useState);",
      );
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(globalDir, 'entry.ts'),
        '--format=iife',
        '--global-name=Lib',
        '--external',
        'react',
        '--global:react=React',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('})(React);');
      expect(stdout).toContain('React.useState');
    } finally {
      rmSync(globalDir, { recursive: true, force: true });
    }
  });

  test('번들 + --format=iife', () => {
    const { stdout, exitCode } = runCli(['--bundle', fixture.entryPoint(), '--format=iife']);
    expect(exitCode).toBe(0);
    expect(stdout.includes('(function') || stdout.includes('(()')).toBe(true);
  });

  test('번들 + --banner:js + --footer:js (esbuild 호환 alias)', () => {
    const { stdout, exitCode } = runCli([
      '--bundle',
      fixture.entryPoint(),
      '--banner:js=/* banner */',
      '--footer:js=/* footer */',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* banner */');
    expect(stdout).toContain('/* footer */');
  });

  test('번들 + --banner + --footer (정식 형태 — BuildOptions.banner 와 1:1)', () => {
    const { stdout, exitCode } = runCli([
      '--bundle',
      fixture.entryPoint(),
      '--banner=/* TOP */',
      '--footer=/* BOTTOM */',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* TOP */');
    expect(stdout).toContain('/* BOTTOM */');
  });

  test('--banner 가 = 안의 = 도 보존', () => {
    const { stdout, exitCode } = runCli([
      '--bundle',
      fixture.entryPoint(),
      '--banner=/* key=value */',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* key=value */');
  });
});
