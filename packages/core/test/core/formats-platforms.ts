import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('@zntc/core 번들 포맷/플랫폼', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-format-'));
    writeFileSync(join(dir, 'index.ts'), 'export const greeting = "hello";\nexport default 42;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('IIFE 포맷', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      format: 'iife',
    });
    expect(result.errors.length).toBe(0);
    // IIFE는 즉시 실행 함수로 감싸짐
    expect(
      result.outputFiles[0].text.includes('(function') ||
        result.outputFiles[0].text.includes('(() =>') ||
        result.outputFiles[0].text.includes('(()'),
    ).toBe(true);
  });

  test('IIFE + globalName', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      format: 'iife',
      globalName: 'MyLib',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('MyLib');
  });

  test('IIFE + globalName: aliased/default exports become return object properties', () => {
    const aliasDir = mkdtempSync(join(tmpdir(), 'zntc-iife-export-return-'));
    writeFileSync(
      join(aliasDir, 'index.ts'),
      'const internal = 1;\nexport { internal as answer };\nexport default internal;',
    );

    const result = buildSync({
      entryPoints: [join(aliasDir, 'index.ts')],
      format: 'iife',
      globalName: 'MyLib',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('return { answer: internal, default: internal };');
    expect(text).not.toContain(' as ');
    rmSync(aliasDir, { recursive: true, force: true });
  });

  test('platform=node', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      platform: 'node',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('greeting');
  });

  test('platform=react-native', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      platform: 'react-native',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('greeting');
  });

  test('ESM import/export 보존', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      format: 'esm',
    });
    expect(result.errors.length).toBe(0);
    // ESM은 export 키워드 포함
    expect(result.outputFiles[0].text).toContain('greeting');
  });
});
