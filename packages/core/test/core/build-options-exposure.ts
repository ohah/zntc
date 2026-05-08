import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  build,
  buildSync,
  resolve,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  join,
  tmpdir,
  runBundleStdout,
} from './helpers';

describe('BuildOptions: 누락 옵션 노출 (#1005)', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-build-opts-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const fn = () => 1;');
    writeFileSync(join(dir, 'data.txt'), 'hello text');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('target: es5 → arrow function이 function으로 변환됨', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'es5',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('=>');
    expect(result.outputFiles[0].text).toContain('function');
  });

  test('target: esnext → arrow function 유지', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'esnext',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('=>');
  });

  test('loader: .txt=text → 텍스트 파일이 문자열로 export됨', () => {
    writeFileSync(join(dir, 'import-txt.ts'), 'import txt from "./data.txt";\nconsole.log(txt);');
    const result = buildSync({
      entryPoints: [join(dir, 'import-txt.ts')],
      loader: { '.txt': 'text' },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('hello text');
  });

  test('loader: JSON/CSS/asset disk reads + plugin load source stay stable', async () => {
    const fixture = mkdtempSync(join(tmpdir(), 'zntc-resource-read-mtime-'));
    try {
      writeFileSync(
        join(fixture, 'entry.ts'),
        [
          'import data from "./data.json";',
          'import "./style.css";',
          'import text from "./note.txt";',
          'import logo from "./logo.png";',
          'import virtual from "./generated.virtual";',
          'console.log(data.answer, text.trim(), logo.includes(".png"), virtual);',
        ].join('\n'),
      );
      writeFileSync(join(fixture, 'data.json'), '{"answer":42}');
      writeFileSync(join(fixture, 'style.css'), '.card { color: red; }\n');
      writeFileSync(join(fixture, 'note.txt'), 'hello resource\n');
      writeFileSync(join(fixture, 'logo.png'), 'png-bytes');

      const plugin: ZntcPlugin = {
        name: 'virtual-source',
        setup(build) {
          build.onResolve({ filter: /\.virtual$/ }, (args) => ({
            path: resolve(fixture, args.path),
          }));
          build.onLoad({ filter: /\.virtual$/ }, () => ({
            contents: 'export default "plugin-source";',
            loader: 'js',
          }));
        },
      };

      const result = await build({
        entryPoints: [join(fixture, 'entry.ts')],
        loader: { '.txt': 'text', '.png': 'file' },
        plugins: [plugin],
      });

      expect(result.errors.length).toBe(0);
      expect(await runBundleStdout(result.outputFiles[0].text)).toBe(
        '42 hello resource true plugin-source',
      );
    } finally {
      rmSync(fixture, { recursive: true, force: true });
    }
  });

  test('loader: .foo=ts → 커스텀 확장자를 TypeScript로 파싱', async () => {
    writeFileSync(
      join(dir, 'entry-loader-ts.ts'),
      'import { value } from "./value.foo";\nconsole.log(value);',
    );
    writeFileSync(join(dir, 'value.foo'), 'export const value: number = 1;');
    const result = await build({
      entryPoints: [join(dir, 'entry-loader-ts.ts')],
      loader: { '.foo': 'ts' },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain(': number');
    expect(await runBundleStdout(result.outputFiles[0].text)).toBe('1');
  });

  test('loader: .foo=ts → JSX syntax를 거부', async () => {
    writeFileSync(
      join(dir, 'entry-loader-ts-no-jsx.ts'),
      'import { value } from "./view-ts-no-jsx.foo";\nconsole.log(value);',
    );
    writeFileSync(
      join(dir, 'view-ts-no-jsx.foo'),
      'const h = (tag) => tag;\nexport const value = <div />;',
    );
    const result = await build({
      entryPoints: [join(dir, 'entry-loader-ts-no-jsx.ts')],
      loader: { '.foo': 'ts' },
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test('loader: .foo=tsx → 커스텀 확장자에서 TSX를 파싱', async () => {
    writeFileSync(
      join(dir, 'entry-loader-tsx.ts'),
      'import { value } from "./view.foo";\nconsole.log(value);',
    );
    writeFileSync(
      join(dir, 'view.foo'),
      'const h = (tag: string) => tag;\nexport const value: string = <div />;',
    );
    const result = await build({
      entryPoints: [join(dir, 'entry-loader-tsx.ts')],
      loader: { '.foo': 'tsx' },
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('<div');
    expect(result.outputFiles[0].text).not.toContain(': string');
    expect(await runBundleStdout(result.outputFiles[0].text)).toBe('div');
  });

  test('loader: .foo=jsx → 커스텀 확장자에서 JSX를 파싱', async () => {
    writeFileSync(
      join(dir, 'entry-loader-jsx.ts'),
      'import { value } from "./view-jsx.foo";\nconsole.log(value);',
    );
    writeFileSync(
      join(dir, 'view-jsx.foo'),
      'const h = (tag) => tag;\nexport const value = <span />;',
    );
    const result = await build({
      entryPoints: [join(dir, 'entry-loader-jsx.ts')],
      loader: { '.foo': 'jsx' },
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('<span');
    expect(await runBundleStdout(result.outputFiles[0].text)).toBe('span');
  });

  test('loader: .foo=js/jsx → TypeScript syntax를 거부', async () => {
    writeFileSync(
      join(dir, 'entry-loader-js-strict.ts'),
      'import { value } from "./value-js-strict.foo";\nconsole.log(value);',
    );
    writeFileSync(join(dir, 'value-js-strict.foo'), 'export const value: number = 1;');
    const jsResult = await build({
      entryPoints: [join(dir, 'entry-loader-js-strict.ts')],
      loader: { '.foo': 'js' },
    });
    expect(jsResult.errors.length).toBeGreaterThan(0);
    expect(jsResult.errors[0].text).toContain('TypeScript');

    writeFileSync(
      join(dir, 'entry-loader-jsx-strict.ts'),
      'import { value } from "./value-jsx-strict.foo";\nconsole.log(value);',
    );
    writeFileSync(
      join(dir, 'value-jsx-strict.foo'),
      'const h = (tag) => tag;\nexport const value: string = <span />;',
    );
    const jsxResult = await build({
      entryPoints: [join(dir, 'entry-loader-jsx-strict.ts')],
      loader: { '.foo': 'jsx' },
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(jsxResult.errors.length).toBeGreaterThan(0);
    expect(jsxResult.errors[0].text).toContain('TypeScript');
  });

  test('resolveExtensions: 커스텀 확장자 순서가 적용됨', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      resolveExtensions: ['.ts', '.tsx', '.js'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test('mainFields: 커스텀 필드 순서가 적용됨', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      mainFields: ['module', 'main'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test('conditions: 커스텀 exports 조건이 적용됨', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      conditions: ['import', 'default'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test('write + outdir: 디스크에 파일이 기록됨', () => {
    const outdir = join(dir, 'out-dir');
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outdir,
      write: true,
    });
    expect(result.errors.length).toBe(0);
    const written = readFileSync(join(outdir, 'bundle.js'), 'utf-8');
    expect(written).toContain('fn');
    rmSync(outdir, { recursive: true, force: true });
  });

  test('outfile: 단일 파일 출력 경로 지정', () => {
    const outfile = join(dir, 'custom-out', 'my-bundle.js');
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outfile,
    });
    expect(result.errors.length).toBe(0);
    const written = readFileSync(outfile, 'utf-8');
    expect(written).toContain('fn');
    rmSync(join(dir, 'custom-out'), { recursive: true, force: true });
  });

  test('outdir 지정 시 write 자동 true', () => {
    const outdir = join(dir, 'auto-write');
    buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outdir,
    });
    const written = readFileSync(join(outdir, 'bundle.js'), 'utf-8');
    expect(written).toContain('fn');
    rmSync(outdir, { recursive: true, force: true });
  });

  test('write: false → 디스크에 기록하지 않음', () => {
    const outdir = join(dir, 'no-write');
    buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outdir,
      write: false,
    });
    expect(() => readFileSync(join(outdir, 'bundle.js'))).toThrow();
  });

  test('outfile + sourcemap: 소스맵이 outfile 옆에 생성됨', () => {
    const outfile = join(dir, 'sm-out', 'bundle.js');
    buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outfile,
      sourcemap: true,
    });
    const mapContent = readFileSync(outfile + '.map', 'utf-8');
    expect(mapContent).toContain('mappings');
    rmSync(join(dir, 'sm-out'), { recursive: true, force: true });
  });
});

// ─── vitePlugin async 훅 테스트 (#1007) ───
