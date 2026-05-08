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

describe('CLI: bundle syntax and targets', () => {
  test('번들 + --target=es5 (ES 다운레벨)', () => {
    const arrowDir = mkdtempSync(join(tmpdir(), 'zntc-cli-target-'));
    try {
      writeFileSync(join(arrowDir, 'entry.ts'), 'const fn = () => 42; console.log(fn());');
      const { stdout, exitCode } = runCli(['--bundle', join(arrowDir, 'entry.ts'), '--target=es5']);
      expect(exitCode).toBe(0);
      expect(stdout).not.toContain('=>');
    } finally {
      rmSync(arrowDir, { recursive: true, force: true });
    }
  });

  test('번들 + --browserslist (target 보다 우선, modern 쿼리는 arrow 보존)', () => {
    const blDir = mkdtempSync(join(tmpdir(), 'zntc-cli-browserslist-'));
    try {
      writeFileSync(join(blDir, 'entry.ts'), 'const fn = () => 42; console.log(fn());');
      const { stdout, exitCode } = runCli([
        '--bundle',
        join(blDir, 'entry.ts'),
        '--target=es5',
        '--browserslist=last 1 chrome version',
      ]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('=>');
    } finally {
      rmSync(blDir, { recursive: true, force: true });
    }
  });

  test('--emit-decorator-metadata + --experimental-decorators', () => {
    const decDir = mkdtempSync(join(tmpdir(), 'zntc-cli-decorator-'));
    try {
      writeFileSync(
        join(decDir, 'entry.ts'),
        "function dec(t: unknown, k: string) {} class C { @dec method(): string { return 'OK'; } } console.log('ok');",
      );
      const { exitCode } = runCli([
        '--bundle',
        join(decDir, 'entry.ts'),
        '--experimental-decorators',
        '--emit-decorator-metadata',
      ]);
      expect(exitCode).toBe(0);
    } finally {
      rmSync(decDir, { recursive: true, force: true });
    }
  });

  test('--jsx-in-js — .js 파일에서도 JSX 파싱 (classic 모드 — runtime resolve 회피)', () => {
    const jsxDir = mkdtempSync(join(tmpdir(), 'zntc-cli-jsx-in-js-'));
    try {
      writeFileSync(
        join(jsxDir, 'entry.js'),
        'function React_createElement() {} const el = <div>OK</div>; console.log(el);',
      );
      const { stdout, exitCode } = runCli([
        '--bundle',
        join(jsxDir, 'entry.js'),
        '--jsx-in-js',
        '--jsx=classic',
        '--jsx-factory=React_createElement',
      ]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('React_createElement');
      expect(stdout).not.toContain('<div>');
    } finally {
      rmSync(jsxDir, { recursive: true, force: true });
    }
  });

  test('--verbatim-module-syntax — flag 가 NAPI 까지 reach (실 동작 미구현은 별도)', () => {
    const vmsDir = mkdtempSync(join(tmpdir(), 'zntc-cli-vms-'));
    try {
      writeFileSync(
        join(vmsDir, 'entry.ts'),
        "import type { X } from './t.ts';\nimport { y } from './t.ts';\nconsole.log(y);",
      );
      writeFileSync(join(vmsDir, 't.ts'), 'export type X = number;\nexport const y = 1;');
      const { stdout, exitCode } = runCli([join(vmsDir, 'entry.ts'), '--verbatim-module-syntax']);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('import');
    } finally {
      rmSync(vmsDir, { recursive: true, force: true });
    }
  });
});
