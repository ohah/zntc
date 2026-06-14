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
} from '../helpers';

describe('import.meta.glob > basic patterns', () => {
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

  test('#4372 minify 시 glob 객체에 newline/공백 없음 (minify invariant)', () => {
    writeFileSync(
      join(dir, 'min.ts'),
      'const m = import.meta.glob("./pages/*.tsx");\nexport { m };',
    );
    const result = buildSync({ entryPoints: [join(dir, 'min.ts')], format: 'esm', minify: true });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    // 과거 glob 객체는 하드코딩 "\n"/"  " 와 `() => ` 공백을 minify 출력에도 흘렸다.
    expect(text).toContain('"./pages/Home.tsx":()=>import(');
    expect(text).not.toContain('"./pages/Home.tsx": (');
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
});
