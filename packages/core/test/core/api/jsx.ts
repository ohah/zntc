import { describe, test, expect, transpile } from '../helpers';

describe('@zntc/core API: JSX', () => {
  test('JSX 트랜스파일 (classic)', () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      jsx: 'classic',
    });
    expect(result.code).toContain('React.createElement');
  });

  test('JSX 트랜스파일 (automatic)', () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      jsx: 'automatic',
    });
    expect(result.code).toContain('jsx');
  });

  test('tsconfigRaw 의 jsx + jsxImportSource 가 자동 매핑돼 적용', () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      tsconfigRaw: JSON.stringify({
        compilerOptions: { jsx: 'react-jsx', jsxImportSource: 'preact' },
      }),
    });
    expect(result.code).toContain('preact/jsx-runtime');
  });

  test('tsconfigRaw 위에 명시 옵션이 우선', () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      jsx: 'classic',
      tsconfigRaw: JSON.stringify({
        compilerOptions: { jsx: 'react-jsx', jsxImportSource: 'preact' },
      }),
    });
    expect(result.code).toContain('React.createElement');
    expect(result.code).not.toContain('preact/jsx-runtime');
  });

  test('filename으로 확장자 감지 (.tsx)', () => {
    const result = transpile('const el = <div />;', { filename: 'comp.tsx' });
    expect(result.code).not.toContain('<div');
  });

  test('JSX 트랜스파일 (automatic-dev)', () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      jsx: 'automatic-dev',
    });
    expect(result.code).toContain('jsxDEV');
  });

  test('jsxFactory 커스텀', () => {
    const result = transpile('<div />', {
      filename: 'app.tsx',
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(result.code).toContain('h(');
    expect(result.code).not.toContain('React.createElement');
  });

  test('jsxImportSource 커스텀', () => {
    const result = transpile('<div />', {
      filename: 'app.tsx',
      jsx: 'automatic',
      jsxImportSource: 'preact',
    });
    expect(result.code).toContain('preact');
  });
});
