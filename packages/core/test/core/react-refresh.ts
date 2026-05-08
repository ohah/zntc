import {
  describe,
  test,
  expect,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('React Refresh: function expression', () => {
  test('function expression 이름이 $RefreshReg$에 등록되지 않아야 함', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `
      const MyComp = function MyCompFactory() { return null; };
      export default MyComp;
    `,
    );
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    // function expression 이름 "MyCompFactory"가 $RefreshReg$에 등록되면 안 됨
    expect(code).not.toContain('$RefreshReg$(_c, "MyCompFactory")');
    // function declaration이 아니므로 외부에서 참조 불가
    expect(code).not.toContain('_c = MyCompFactory');
    rmSync(dir, { recursive: true });
  });

  test('function declaration은 정상적으로 $RefreshReg$에 등록', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `
      function MyComponent() { return null; }
      export default MyComponent;
    `,
    );
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    // function declaration 이름 "MyComponent"는 등록되어야 함
    expect(code).toContain('MyComponent');
    expect(code).toContain('$RefreshReg$');
    rmSync(dir, { recursive: true });
  });

  test('named function expression을 인자로 전달해도 $RefreshReg$ 미등록', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `
      function App() {
        const handler = someHook(function HandlerFactory() { return 1; }, []);
        return handler;
      }
      export default App;
    `,
    );
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    expect(code).not.toContain('"HandlerFactory"');
    rmSync(dir, { recursive: true });
  });

  test('arrow function은 변수명이 PascalCase면 $RefreshReg$ 등록', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(join(dir, 'entry.ts'), `const MyArrow = () => null;\nexport default MyArrow;\n`);
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    expect(code).toContain('$RefreshReg$');
    rmSync(dir, { recursive: true });
  });

  test('lowercase function name은 $RefreshReg$ 미등록 (컴포넌트 아님)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `function helper() { return 1; }\nexport default helper;\n`,
    );
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    // lowercase 함수는 컴포넌트가 아니므로 등록 안 함
    expect(code).not.toContain('"helper"');
    rmSync(dir, { recursive: true });
  });

  test('export default function declaration은 $RefreshReg$ 등록', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(join(dir, 'entry.ts'), `export default function MyScreen() { return null; }\n`);
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    // export default function은 declaration → 등록됨
    expect(code).toContain('$RefreshReg$');
    expect(code).toContain('MyScreen');
    rmSync(dir, { recursive: true });
  });

  test('class component는 $RefreshReg$ 미등록 (함수만 등록)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `class MyClassComp { render() { return null; } }\nexport default MyClassComp;\n`,
    );
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    // class는 React Refresh 등록 대상이 아님 (함수 컴포넌트만 등록)
    expect(code).not.toContain('"MyClassComp"');
    rmSync(dir, { recursive: true });
  });
});

// ================================================================
// watch() API 테스트
// ================================================================
