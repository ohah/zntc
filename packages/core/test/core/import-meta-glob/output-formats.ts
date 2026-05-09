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

describe('import.meta.glob > output formats', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-glob-'));
    mkdirSync(join(dir, 'pages'), { recursive: true });
    writeFileSync(join(dir, 'pages', 'Home.tsx'), 'export default "Home";');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
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
});
