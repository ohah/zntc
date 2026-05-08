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
import type { ZntcPlugin } from './helpers';

describe('@zntc/core plugin onLoad loader > standard loaders', () => {
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
});
