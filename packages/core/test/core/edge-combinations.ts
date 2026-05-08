import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  build,
  buildSync,
  vitePlugin,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  join,
  tmpdir,
  ROOT_NODE_MODULES,
} from './helpers';

describe('엣지 케이스 + 조합 보강', () => {
  let dir: string;
  const projectNodeModules = ROOT_NODE_MODULES;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-edge2-'));
    writeFileSync(join(dir, 'simple.ts'), 'export const x = () => 1;');
    writeFileSync(
      join(dir, 'multi-export.ts'),
      'export const a = 1;\nexport const b = 2;\nexport function add() { return a + b; }',
    );
    writeFileSync(join(dir, 'has-console.ts'), 'console.log("hello");\nexport const v = 1;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  // --- target + format 조합 ---

  test('target: es5 + format: umd → arrow 변환 + UMD 래핑', async () => {
    const result = await build({
      entryPoints: [join(dir, 'simple.ts')],
      target: 'es5',
      format: 'umd',
      globalName: 'Lib',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).not.toContain('=>');
    expect(text).toContain('typeof define');
    expect(text).toContain('factory');
  });

  test('target: es5 + format: amd → arrow 변환 + AMD 래핑', async () => {
    const result = await build({
      entryPoints: [join(dir, 'simple.ts')],
      target: 'es5',
      format: 'amd',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('=>');
    expect(result.outputFiles[0].text).toContain('define([]');
  });

  // --- dropLabels + minify ---

  test('dropLabels + minify: 라벨 제거 후 압축', () => {
    writeFileSync(join(dir, 'label-min.ts'), 'DEV: { console.log("dev"); }\nexport const x = 1;');
    const result = buildSync({
      entryPoints: [join(dir, 'label-min.ts')],
      dropLabels: ['DEV'],
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('dev');
  });

  // --- 다중 포맷 런타임 검증 ---

  test('format: esm → export 구문 유지', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'multi-export.ts')],
      format: 'esm',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('export');
  });

  test('format: cjs + minify', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'simple.ts')],
      format: 'cjs',
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('"use strict"');
  });

  // --- sourcemap 조합 ---

  test('sourcemap + minify + target: es5', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'simple.ts')],
      sourcemap: true,
      minify: true,
      target: 'es5',
    });
    expect(result.errors.length).toBe(0);
    const mapFile = result.outputFiles.find((f: any) => f.path.endsWith('.map'));
    expect(mapFile).toBeDefined();
    expect(mapFile!.text).toContain('mappings');
  });

  // --- 플러그인 + 옵션 조합 ---

  test('플러그인 onTransform + target', async () => {
    const result = await build({
      entryPoints: [join(dir, 'has-console.ts')],
      target: 'es2020',
      plugins: [
        vitePlugin({
          name: 'replacer',
          transform(code) {
            return code.replace('hello', 'TRANSFORMED');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('TRANSFORMED');
  });

  test('플러그인 renderChunk + format: umd', async () => {
    const result = await build({
      entryPoints: [join(dir, 'simple.ts')],
      format: 'umd',
      globalName: 'T',
      plugins: [
        vitePlugin({
          name: 'chunk-stamp',
          renderChunk(code) {
            return `/* stamped */\n${code}`;
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('/* stamped */');
    expect(result.outputFiles[0].text).toContain('typeof define');
  });

  // --- 빈 입력 / 에러 ---

  test('존재하지 않는 파일 → 에러', () => {
    const result = buildSync({ entryPoints: [join(dir, 'nonexistent.ts')] });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test('빈 파일 → 정상 빌드', () => {
    writeFileSync(join(dir, 'empty.ts'), '');
    const result = buildSync({ entryPoints: [join(dir, 'empty.ts')] });
    expect(result.errors.length).toBe(0);
  });

  // --- write + 다양한 포맷 ---

  test('write + outdir + format: umd', () => {
    const outdir = join(dir, 'umd-out');
    const result = buildSync({
      entryPoints: [join(dir, 'simple.ts')],
      format: 'umd',
      globalName: 'W',
      outdir,
    });
    expect(result.errors.length).toBe(0);
    const written = readFileSync(join(outdir, 'bundle.js'), 'utf-8');
    expect(written).toContain('typeof define');
    rmSync(outdir, { recursive: true, force: true });
  });

  // --- React + 다양한 포맷 ---

  test('React: AMD + external → define 래핑', async () => {
    writeFileSync(
      join(dir, 'react-amd.tsx'),
      'import React from "react";\nexport const el = React.createElement("div");',
    );
    const result = await build({
      entryPoints: [join(dir, 'react-amd.tsx')],
      format: 'amd',
      external: ['react'],
      jsx: 'classic',
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('define(["react"]');
    expect(result.outputFiles[0].text).toContain('function(React)');
  });

  // --- minifyIdentifiers + for-in (NAPI 레벨 검증) ---

  test('minifyIdentifiers: for-in LHS 변수가 올바르게 리네이밍됨', () => {
    writeFileSync(
      join(dir, 'forin.js'),
      'var myObj = { a: 1 };\nvar myKey;\nfor (myKey in myObj) { console.log(myKey); }\nexport var result = myKey;',
    );
    const result = buildSync({
      entryPoints: [join(dir, 'forin.js')],
      format: 'esm',
      minifyIdentifiers: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('myKey');
    expect(result.outputFiles[0].text).not.toContain('myObj');
  });

  test('minifyIdentifiers: 함수 내부 var hoisting', () => {
    writeFileSync(
      join(dir, 'hoist.js'),
      'export default (function() { console.log(longName); var longName = 42; return longName; })();',
    );
    const result = buildSync({
      entryPoints: [join(dir, 'hoist.js')],
      format: 'esm',
      minifyIdentifiers: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('longName');
  });
});

// ================================================================
// React Refresh: function expression 이름 등록 방지
// ================================================================
