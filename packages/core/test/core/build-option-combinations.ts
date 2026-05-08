import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  build,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('@zntc/core build 옵션 조합', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-combo-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import { helper } from "./util";\nconsole.log(helper());',
    );
    writeFileSync(join(dir, 'util.ts'), 'export function helper() { return 42; }');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('minifyWhitespace만 적용', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      minifyWhitespace: true,
    });
    expect(result.errors.length).toBe(0);
    // 줄바꿈/공백이 줄어듦
    expect(result.outputFiles[0].text.split('\n').length).toBeLessThan(20);
  });

  test('minifyIdentifiers 적용 시 출력 크기 감소', () => {
    const normal = buildSync({ entryPoints: [join(dir, 'index.ts')] });
    const minified = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      minifyIdentifiers: true,
    });
    expect(minified.errors.length).toBe(0);
    // 식별자 축소로 출력이 줄어들거나 동일 (scope hoist 인라인 시)
    expect(minified.outputFiles[0].text.length).toBeLessThanOrEqual(
      normal.outputFiles[0].text.length,
    );
  });

  test('sourcemap + minify + metafile 동시', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      minify: true,
      sourcemap: true,
      metafile: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBe(2); // js + map
    expect(result.metafile).toBeDefined();
    const map = JSON.parse(result.outputFiles.find((f) => f.path.endsWith('.map'))!.text);
    expect(map.version).toBe(3);
  });

  test('treeShaking=false로 미사용 export 보존', () => {
    const tsDir = mkdtempSync(join(tmpdir(), 'zntc-tree-'));
    writeFileSync(join(tsDir, 'index.ts'), 'import { used } from "./lib";\nconsole.log(used);');
    writeFileSync(join(tsDir, 'lib.ts'), 'export const used = 1;\nexport const unused = 2;');

    const withTree = buildSync({
      entryPoints: [join(tsDir, 'index.ts')],
      treeShaking: true,
    });
    const withoutTree = buildSync({
      entryPoints: [join(tsDir, 'index.ts')],
      treeShaking: false,
    });
    // tree-shaking 끄면 unused도 포함
    expect(withoutTree.outputFiles[0].text).toContain('unused');
    // tree-shaking 켜면 unused 제거 (scope hoist 활성화 시)
    expect(withTree.outputFiles[0].text).not.toContain('unused');
    rmSync(tsDir, { recursive: true, force: true });
  });

  test('JSX automatic + build', () => {
    const jsxDir = mkdtempSync(join(tmpdir(), 'zntc-jsx-build-'));
    writeFileSync(join(jsxDir, 'app.tsx'), 'export default () => <div>hello</div>;');

    const result = buildSync({
      entryPoints: [join(jsxDir, 'app.tsx')],
      jsx: 'automatic',
      jsxInJs: true,
      external: ['react/jsx-runtime'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('jsx-runtime');
    rmSync(jsxDir, { recursive: true, force: true });
  });

  test('Flow 파일 번들링', () => {
    const flowDir = mkdtempSync(join(tmpdir(), 'zntc-flow-build-'));
    writeFileSync(
      join(flowDir, 'index.js'),
      '// @flow\nfunction foo(x: string): number { return x.length; }\nconsole.log(foo("test"));',
    );

    const result = buildSync({
      entryPoints: [join(flowDir, 'index.js')],
      flow: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain(': string');
    expect(result.outputFiles[0].text).not.toContain(': number');
    rmSync(flowDir, { recursive: true, force: true });
  });

  test('build async: 동시 5개 호출', async () => {
    const results = await Promise.all(
      Array.from({ length: 5 }, () => build({ entryPoints: [join(dir, 'index.ts')] })),
    );
    for (const r of results) {
      expect(r.errors.length).toBe(0);
      expect(r.outputFiles[0].text).toContain('helper');
    }
  });
});

// ─── ES2023 + hashbang ───
