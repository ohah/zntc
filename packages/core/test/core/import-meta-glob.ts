import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  buildSync,
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('import.meta.glob', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-glob-'));
    mkdirSync(join(dir, 'pages'), { recursive: true });
    writeFileSync(join(dir, 'pages', 'Home.tsx'), 'export default "Home";');
    writeFileSync(join(dir, 'pages', 'About.tsx'), 'export default "About";');
    writeFileSync(join(dir, 'pages', 'Contact.tsx'), 'export default "Contact";');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('기본 glob: lazy import 객체 생성', () => {
    writeFileSync(
      join(dir, 'entry.ts'),
      'const m = import.meta.glob("./pages/*.tsx");\nexport { m };',
    );
    const result = buildSync({ entryPoints: [join(dir, 'entry.ts')], format: 'esm' });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('./pages/Home.tsx');
    expect(text).toContain('./pages/About.tsx');
    expect(text).toContain('./pages/Contact.tsx');
    expect(text).toContain('() => import(');
    expect(text).not.toContain('import.meta.glob');
  });

  test('매칭 파일 없는 패턴 → 빈 객체', () => {
    writeFileSync(
      join(dir, 'empty.ts'),
      'const m = import.meta.glob("./nonexistent/*.ts");\nexport { m };',
    );
    const result = buildSync({ entryPoints: [join(dir, 'empty.ts')], format: 'esm' });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('import(');
  });

  test('다른 확장자 패턴', () => {
    writeFileSync(join(dir, 'pages', 'data.json'), '{"key":"value"}');
    writeFileSync(
      join(dir, 'json-glob.ts'),
      'const m = import.meta.glob("./pages/*.json");\nexport { m };',
    );
    const result = buildSync({ entryPoints: [join(dir, 'json-glob.ts')], format: 'esm' });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('./pages/data.json');
  });

  test('glob + IIFE 포맷 → 객체 리터럴 출력', () => {
    writeFileSync(
      join(dir, 'iife-glob.ts'),
      'const m = import.meta.glob("./pages/*.tsx");\nexport { m };',
    );
    const result = buildSync({
      entryPoints: [join(dir, 'iife-glob.ts')],
      format: 'iife',
      globalName: 'G',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('./pages/Home.tsx');
    expect(text).toContain('() => import(');
    expect(text).not.toContain('import.meta.glob');
  });

  test('glob + minify → 축소 후에도 정상 출력', () => {
    writeFileSync(
      join(dir, 'min-glob.ts'),
      'const m = import.meta.glob("./pages/*.tsx");\nexport { m };',
    );
    const result = buildSync({
      entryPoints: [join(dir, 'min-glob.ts')],
      format: 'esm',
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('./pages/Home.tsx');
    expect(text).toContain('import(');
    expect(text).not.toContain('import.meta.glob');
  });

  test('glob: 코드 내 문자열에 import.meta.glob이 있어도 오탐 안 함', () => {
    writeFileSync(
      join(dir, 'no-false-match.ts'),
      'const msg = "use import.meta.glob() to load";\nexport { msg };',
    );
    const result = buildSync({ entryPoints: [join(dir, 'no-false-match.ts')], format: 'esm' });
    expect(result.errors.length).toBe(0);
    // 문자열 리터럴 안의 import.meta.glob은 교체되지 않아야 함
    expect(result.outputFiles[0].text).toContain('import.meta.glob');
  });
});

// ─── 추가 엣지 케이스 + 조합 테스트 ───
