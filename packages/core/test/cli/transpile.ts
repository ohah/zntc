import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  tmpdir,
  join,
  runCli,
} from './helpers';

describe('CLI: transpile', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-cli-transpile-'));
    writeFileSync(join(dir, 'input.ts'), 'const x: number = 1;\nconsole.log(x);');
    writeFileSync(
      join(dir, 'types.ts'),
      'interface Foo { bar: string; }\ntype Baz = number;\nconst y = 42;',
    );
    writeFileSync(join(dir, 'jsx.tsx'), 'export default () => <div>hello</div>;');
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('파일 트랜스파일 → stdout', () => {
    const { stdout, exitCode } = runCli([join(dir, 'input.ts')]);
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
    const outFile = join(dir, 'output.js');
    const { exitCode } = runCli([join(dir, 'input.ts'), '-o', outFile]);
    expect(exitCode).toBe(0);
    expect(existsSync(outFile)).toBe(true);
    const content = readFileSync(outFile, 'utf8');
    expect(content).toContain('const x = 1');
  });

  test('파일 트랜스파일 → --outdir 출력', () => {
    const outDir = join(dir, 'out');
    const { exitCode } = runCli([join(dir, 'input.ts'), '--outdir', outDir]);
    expect(exitCode).toBe(0);
    expect(existsSync(join(outDir, 'input.js'))).toBe(true);
  });

  test('--allow-overwrite 미지정 시 입력=출력 차단', () => {
    const outFile = join(dir, 'input.ts');
    const { exitCode, stderr } = runCli([join(dir, 'input.ts'), '-o', outFile]);
    expect(exitCode).toBe(1);
    expect(stderr).toContain('would overwrite input file');
    expect(stderr).toContain('--allow-overwrite');
  });

  test('--allow-overwrite 지정 시 입력=출력 허용', () => {
    const overwriteDir = mkdtempSync(join(tmpdir(), 'zntc-cli-overwrite-'));
    try {
      const file = join(overwriteDir, 'input.ts');
      writeFileSync(file, 'const x: number = 1;\n');
      const { exitCode, stderr } = runCli([file, '-o', file, '--allow-overwrite']);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('would overwrite');
      expect(readFileSync(file, 'utf8')).toContain('const x = 1');
    } finally {
      rmSync(overwriteDir, { recursive: true, force: true });
    }
  });

  test('--allow-overwrite 미지정 시 --outdir 의 동일 JS 입력 overwrite 차단', () => {
    const overwriteDir = mkdtempSync(join(tmpdir(), 'zntc-cli-overwrite-outdir-'));
    try {
      const file = join(overwriteDir, 'input.js');
      writeFileSync(file, 'const x = 1;\n');
      const { exitCode, stderr } = runCli([file, '--outdir', overwriteDir]);
      expect(exitCode).toBe(1);
      expect(stderr).toContain('would overwrite input file');
    } finally {
      rmSync(overwriteDir, { recursive: true, force: true });
    }
  });

  test('타입/인터페이스만 있는 파일 → 빈 출력', () => {
    const { stdout, exitCode } = runCli([join(dir, 'types.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('interface');
    expect(stdout).not.toContain('type Baz');
    expect(stdout).toContain('y = 42');
  });

  test('--minify 옵션', () => {
    const normal = runCli([join(dir, 'input.ts')]);
    const minified = runCli([join(dir, 'input.ts'), '--minify']);
    expect(minified.exitCode).toBe(0);
    expect(minified.stdout.length).toBeLessThan(normal.stdout.length);
  });

  test('--sourcemap 옵션 + -o', () => {
    const outFile = join(dir, 'with-map.js');
    const { exitCode } = runCli([join(dir, 'input.ts'), '--sourcemap', '-o', outFile]);
    expect(exitCode).toBe(0);
    expect(existsSync(outFile)).toBe(true);
    expect(existsSync(outFile + '.map')).toBe(true);
    const map = JSON.parse(readFileSync(outFile + '.map', 'utf8'));
    expect(map.version).toBe(3);
  });

  test('--format=cjs', () => {
    const { stdout, exitCode } = runCli([join(dir, 'input.ts'), '--format=cjs']);
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

  test('--tsconfig-raw applies inline compilerOptions', () => {
    const raw = JSON.stringify({
      compilerOptions: { jsx: 'react-jsx', jsxImportSource: 'preact' },
    });
    const { stdout, exitCode } = runCli([join(dir, 'jsx.tsx'), `--tsconfig-raw=${raw}`]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('preact/jsx-runtime');
    expect(stdout).toContain('_jsx');
  });

  test('--tsconfig-raw does not override explicit CLI flags', () => {
    const raw = JSON.stringify({
      compilerOptions: { jsx: 'react-jsx', jsxImportSource: 'preact' },
    });
    const { stdout, exitCode } = runCli([
      join(dir, 'jsx.tsx'),
      `--tsconfig-raw=${raw}`,
      '--jsx=classic',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('preact/jsx-runtime');
    expect(stdout).toContain('React.createElement');
  });

  test('--tsconfig-raw takes precedence over --project file fallback', () => {
    const projectDir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-raw-'));
    try {
      writeFileSync(
        join(projectDir, 'tsconfig.json'),
        JSON.stringify({ compilerOptions: { jsx: 'react' } }),
      );
      const raw = JSON.stringify({
        compilerOptions: { jsx: 'react-jsx', jsxImportSource: 'preact' },
      });
      const { stdout, exitCode } = runCli([
        join(dir, 'jsx.tsx'),
        '--project',
        projectDir,
        `--tsconfig-raw=${raw}`,
      ]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('preact/jsx-runtime');
    } finally {
      rmSync(projectDir, { recursive: true, force: true });
    }
  });

  test('--tsconfig-raw invalid JSON reports a diagnostic', () => {
    const { stderr, exitCode } = runCli([join(dir, 'input.ts'), '--tsconfig-raw={']);
    expect(exitCode).toBe(1);
    expect(stderr).toContain('failed to parse --tsconfig-raw');
  });

  test('--tsconfig-raw rejects non-object top-level JSON', () => {
    for (const value of ['null', '[]', '42', '"string"']) {
      const { stderr, exitCode } = runCli([join(dir, 'input.ts'), `--tsconfig-raw=${value}`]);
      expect(exitCode).toBe(1);
      expect(stderr).toContain('expected a JSON object');
    }
  });

  test('file-based jsx tsconfig (jsxImportSource=preact) is honored via NAPI', () => {
    // tsconfig 의 jsx/jsxImportSource 가 NAPI(Zig `tsconfig_merge`) 경로로 적용되는지 회귀 가드.
    const projectDir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-jsx-'));
    try {
      writeFileSync(
        join(projectDir, 'tsconfig.json'),
        JSON.stringify({
          compilerOptions: { jsx: 'react-jsx', jsxImportSource: 'preact' },
        }),
      );
      const { stdout, exitCode } = runCli([join(dir, 'jsx.tsx'), '--project', projectDir]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('preact/jsx-runtime');
    } finally {
      rmSync(projectDir, { recursive: true, force: true });
    }
  });

  test('--drop=console', () => {
    const { stdout, exitCode } = runCli([join(dir, 'input.ts'), '--drop=console']);
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('console.log');
  });

  test('--tokenize prints scanner tokens', () => {
    const { stdout, stderr, exitCode } = runCli([join(dir, 'input.ts'), '--tokenize']);
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('unknown option');
    expect(stdout).toContain('const');
    expect(stdout).toContain('<identifier>');
    expect(stdout).toContain('<eof>');
    expect(stdout).not.toContain('const x = 1');
  });

  test('--tokenize-format=json prints machine-readable tokens', () => {
    const { stdout, exitCode } = runCli([
      join(dir, 'input.ts'),
      '--tokenize',
      '--tokenize-format=json',
    ]);
    expect(exitCode).toBe(0);
    const tokens = JSON.parse(stdout);
    expect(tokens.some((token: any) => token.kind === 'const')).toBe(true);
    expect(tokens.some((token: any) => token.kind === '<eof>')).toBe(true);
  });

  test('--profile emits profile report in transpile mode', () => {
    const { stderr, exitCode } = runCli([
      join(dir, 'input.ts'),
      '--profile=all',
      '--profile-format=table',
    ]);
    expect(exitCode).toBe(0);
    expect(stderr).toContain('Profile');
  });

  test('존재하지 않는 파일 → 에러', () => {
    const { exitCode, stderr } = runCli(['/nonexistent/file.ts']);
    expect(exitCode).toBe(1);
    expect(stderr.length).toBeGreaterThan(0);
  });

  test('인자 없이 실행 → usage 메시지', () => {
    const { exitCode, stderr } = runCli([]);
    expect(exitCode).toBe(1);
    expect(stderr).toContain('Usage');
  });
});

// ─── Bundle 모드 ───
