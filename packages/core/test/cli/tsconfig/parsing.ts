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

describe('CLI: tsconfig parsing', () => {
  test('tsconfig.json에 주석이 있어도 파싱 성공', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-comments-'));
    writeFileSync(
      join(dir, 'tsconfig.json'),
      `{
  // 이것은 주석입니다
  "compilerOptions": {
    /* 블록 주석 */
    "experimentalDecorators": true
  }
}`,
    );
    writeFileSync(
      join(dir, 'input.ts'),
      '@sealed\nclass G { x: string; constructor(m: string) { this.x = m; } }',
    );

    const { stdout, exitCode } = runCli([join(dir, 'input.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('__decorate');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig.json 없으면 무시 (에러 없음)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-no-tsconfig-'));
    writeFileSync(join(dir, 'input.ts'), 'const x: number = 1;');

    const { stdout, exitCode } = runCli([join(dir, 'input.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('const x = 1');
    rmSync(dir, { recursive: true, force: true });
  });

  test('useDefineForClassFields=false tsconfig 로드', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-define-fields-'));
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { useDefineForClassFields: false },
      }),
    );
    writeFileSync(join(dir, 'input.ts'), 'class A { x = 1; }');

    const { stdout, exitCode } = runCli([join(dir, 'input.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('this.x');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig에 URL이 포함된 문자열이 있어도 파싱 성공', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-url-'));
    writeFileSync(
      join(dir, 'tsconfig.json'),
      `{
  // tsconfig with URL in value
  "compilerOptions": {
    "experimentalDecorators": true,
    "baseUrl": "https://example.com/path"
  }
}`,
    );
    writeFileSync(
      join(dir, 'input.ts'),
      '@sealed\nclass G { x: string; constructor(m: string) { this.x = m; } }',
    );

    const { stdout, exitCode } = runCli([join(dir, 'input.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('__decorate');
    rmSync(dir, { recursive: true, force: true });
  });
});
