import {
  describe,
  test,
  expect,
  build,
  resolve,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  join,
  tmpdir,
  runBundleStdout,
} from './helpers';

describe('@zntc/core plugin onLoad loader', () => {
  test("loader='text': string default export + Node 실행 결과 일치", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-text-'));
    writeFileSync(join(dir, 'entry.ts'), "import data from './README.md';\nconsole.log(data);");
    writeFileSync(join(dir, 'README.md'), '# hello world');
    const plugin: ZntcPlugin = {
      name: 'md-as-text',
      setup(build) {
        build.onLoad({ filter: /\.md$/ }, (args) => ({
          contents: readFileSync(args.path, 'utf-8'),
          loader: 'text',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(r.outputFiles[0].text).toContain('"# hello world"');
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('# hello world');
    rmSync(dir, { recursive: true });
  });

  test("loader='dataurl': data URL 인라인 + Node 실행 결과 일치", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-dataurl-'));
    writeFileSync(join(dir, 'entry.ts'), "import url from './pic.svg';\nconsole.log(url);");
    writeFileSync(join(dir, 'pic.svg'), '<svg/>');
    const plugin: ZntcPlugin = {
      name: 'svg-as-dataurl',
      setup(build) {
        build.onLoad({ filter: /\.svg$/ }, (args) => ({
          contents: readFileSync(args.path, 'utf-8'),
          loader: 'dataurl',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(r.outputFiles[0].text).toContain('data:image/svg+xml;base64,');
    // base64('<svg/>') = 'PHN2Zy8+'
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('data:image/svg+xml;base64,PHN2Zy8+');
    rmSync(dir, { recursive: true });
  });

  test("loader='base64': 순수 base64 문자열 (data URL prefix 없음)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-b64-'));
    writeFileSync(join(dir, 'entry.ts'), "import s from './data.bin';\nconsole.log(s);");
    writeFileSync(join(dir, 'data.bin'), 'Hi'); // base64('Hi') = 'SGk='
    const plugin: ZntcPlugin = {
      name: 'bin-as-base64',
      setup(build) {
        build.onLoad({ filter: /\.bin$/ }, (args) => ({
          // NAPI 가 현재 contents 를 string 으로만 받음 — utf-8 디코드된 string 전달.
          // 진짜 binary safe (Uint8Array forward) 는 후속 PR.
          contents: readFileSync(args.path, 'utf-8'),
          loader: 'base64',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(r.outputFiles[0].text).toContain('"SGk="');
    expect(r.outputFiles[0].text).not.toContain('data:');
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('SGk=');
    rmSync(dir, { recursive: true });
  });

  test("loader='binary': Uint8Array default export + Node 실행 결과 일치", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-binary-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "import bytes from './data.dat';\nconsole.log(bytes instanceof Uint8Array, bytes.length, bytes[0], bytes[1]);",
    );
    writeFileSync(join(dir, 'data.dat'), 'AB'); // ASCII safe
    const plugin: ZntcPlugin = {
      name: 'dat-as-binary',
      setup(build) {
        // .dat 의 default loader 는 .none — onResolve 로 ZNTC 가 모듈 등록할 path 를 명시,
        // onLoad 가 raw bytes + binary loader override. NAPI string 한계로 utf-8 safe 데이터.
        build.onResolve({ filter: /\.dat$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.dat$/ }, (args) => ({
          contents: readFileSync(args.path, 'utf-8'),
          loader: 'binary',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(r.outputFiles[0].text).toContain('__toBinary');
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('true 2 65 66');
    rmSync(dir, { recursive: true });
  });

  test('contents=Uint8Array (binary safe): 비-utf8 bytes 도 손실 없이 forward (#2157 follow-up)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-uint8-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "import bytes from './data.bin';\nconsole.log(bytes.length, bytes[0], bytes[1], bytes[2], bytes[3]);",
    );
    // PNG magic header — 0x89 / 0xFF 같은 utf-8 invalid bytes 포함
    const rawBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    writeFileSync(join(dir, 'data.bin'), rawBytes);
    const plugin: ZntcPlugin = {
      name: 'bin-as-binary-uint8',
      setup(build) {
        build.onResolve({ filter: /\.bin$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.bin$/ }, (args) => ({
          // 핵심: Uint8Array 그대로 forward — utf-8 디코드 손실 없음
          contents: readFileSync(args.path),
          loader: 'binary',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(r.outputFiles[0].text).toContain('__toBinary');
    // 0x89 = 137, 0x50 = 80, 0x4e = 78, 0x47 = 71. utf-8 디코드 시 0x89 가 손실되어 invalid 였을 것.
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('4 137 80 78 71');
    rmSync(dir, { recursive: true });
  });

  test("contents=Uint8Array + loader='dataurl' (PNG raw bytes 보존)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-png-'));
    writeFileSync(join(dir, 'entry.ts'), "import url from './tiny.png';\nconsole.log(url);");
    const rawBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]); // PNG magic
    writeFileSync(join(dir, 'tiny.png'), rawBytes);
    const plugin: ZntcPlugin = {
      name: 'png-as-dataurl-uint8',
      setup(build) {
        build.onLoad({ filter: /\.png$/ }, (args) => ({
          contents: readFileSync(args.path),
          loader: 'dataurl',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    // base64([0x89,0x50,0x4e,0x47]) = 'iVBORw=='
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('data:image/png;base64,iVBORw==');
    rmSync(dir, { recursive: true });
  });

  test('contents=Buffer (Node Buffer): napi_is_buffer 경로로 raw bytes forward', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-buffer-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "import bytes from './data.raw';\nconsole.log(bytes.length, bytes[0], bytes[1]);",
    );
    const plugin: ZntcPlugin = {
      name: 'raw-as-buffer',
      setup(build) {
        build.onResolve({ filter: /\.raw$/ }, (args) => ({ path: resolve(dir, args.path) }));
        // 핵심: Buffer.from(...) — Node.js Buffer 인스턴스 (Uint8Array subclass 지만 napi_is_buffer 별도)
        build.onLoad({ filter: /\.raw$/ }, () => ({
          contents: Buffer.from([0xff, 0xfe]),
          loader: 'binary',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('2 255 254');
    rmSync(dir, { recursive: true });
  });

  test("loader='empty': default export 가 undefined", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-empty-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "import x from './any.skip';\nconsole.log(x === undefined);",
    );
    writeFileSync(join(dir, 'any.skip'), 'doesnt matter');
    const plugin: ZntcPlugin = {
      name: 'skip-as-empty',
      setup(build) {
        build.onResolve({ filter: /\.skip$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.skip$/ }, () => ({ contents: '', loader: 'empty' }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('true');
    rmSync(dir, { recursive: true });
  });

  test("loader='tsx': onLoad contents를 TSX parser mode로 처리", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-tsx-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { value } from './virtual.foo';\nconsole.log(value);",
    );
    writeFileSync(join(dir, 'virtual.foo'), '');
    const plugin: ZntcPlugin = {
      name: 'foo-as-tsx',
      setup(build) {
        build.onLoad({ filter: /\.foo$/ }, () => ({
          contents: 'const h = (tag: string) => tag;\nexport const value: string = <div />;',
          loader: 'tsx',
        }));
      },
    };
    const r = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [plugin],
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(r.outputFiles[0].text).not.toContain('<div');
    expect(r.outputFiles[0].text).not.toContain(': string');
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('div');
    rmSync(dir, { recursive: true });
  });

  test("loader='js'/'jsx'/'ts'/'tsx': onLoad parser mode strictness", async () => {
    async function runOnLoadCase(loader: 'js' | 'jsx' | 'ts' | 'tsx', contents: string) {
      const dir = mkdtempSync(join(tmpdir(), `zntc-onload-${loader}-strict-`));
      writeFileSync(
        join(dir, 'entry.ts'),
        "import { value } from './virtual.foo';\nconsole.log(value);",
      );
      writeFileSync(join(dir, 'virtual.foo'), '');
      const plugin: ZntcPlugin = {
        name: `foo-as-${loader}`,
        setup(build) {
          build.onLoad({ filter: /\.foo$/ }, () => ({ contents, loader }));
        },
      };
      const r = await build({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [plugin],
        jsx: 'classic',
        jsxFactory: 'h',
      });
      rmSync(dir, { recursive: true, force: true });
      return r;
    }

    const jsResult = await runOnLoadCase('js', 'export const value: number = 1;');
    expect(jsResult.errors.length).toBeGreaterThan(0);
    expect(jsResult.errors[0].text).toContain('TypeScript');

    const tsResult = await runOnLoadCase('ts', 'export const value: number = 1;');
    expect(tsResult.errors.length).toBe(0);
    expect(await runBundleStdout(tsResult.outputFiles[0].text)).toBe('1');

    const tsJsxResult = await runOnLoadCase(
      'ts',
      'const h = (tag) => tag;\nexport const value = <div />;',
    );
    expect(tsJsxResult.errors.length).toBeGreaterThan(0);

    const jsxResult = await runOnLoadCase(
      'jsx',
      'const h = (tag) => tag;\nexport const value = <span />;',
    );
    expect(jsxResult.errors.length).toBe(0);
    expect(await runBundleStdout(jsxResult.outputFiles[0].text)).toBe('span');

    const jsxTsResult = await runOnLoadCase(
      'jsx',
      'const h = (tag) => tag;\nexport const value: string = <span />;',
    );
    expect(jsxTsResult.errors.length).toBeGreaterThan(0);
    expect(jsxTsResult.errors[0].text).toContain('TypeScript');

    const tsxResult = await runOnLoadCase(
      'tsx',
      'const h = (tag: string) => tag;\nexport const value: string = <div />;',
    );
    expect(tsxResult.errors.length).toBe(0);
    expect(await runBundleStdout(tsxResult.outputFiles[0].text)).toBe('div');
  });

  test("loader='bogus' (미지원 string): override 무시 → JS 모듈로 처리 (fromString null)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-bogus-'));
    writeFileSync(join(dir, 'entry.ts'), "import x from './v.custom';\nconsole.log(x);");
    const plugin: ZntcPlugin = {
      name: 'custom-bogus',
      setup(build) {
        build.onResolve({ filter: /\.custom$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.custom$/ }, () => ({
          contents: 'export default 42;',
          // @ts-expect-error — 의도적으로 잘못된 값
          loader: 'bogus',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    // fromString null → loader_override null → default JS 처리 → 정상 import
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('42');
    rmSync(dir, { recursive: true });
  });

  test('loader 없이 반환: 기존 동작 (JS 모듈)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-default-'));
    writeFileSync(join(dir, 'entry.ts'), "import x from './v.custom';\nconsole.log(x);");
    const plugin: ZntcPlugin = {
      name: 'custom-as-js',
      setup(build) {
        build.onResolve({ filter: /\.custom$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.custom$/ }, () => ({ contents: 'export default 42;' }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('42');
    rmSync(dir, { recursive: true });
  });
});
