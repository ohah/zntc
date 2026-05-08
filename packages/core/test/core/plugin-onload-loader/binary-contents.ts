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

describe('@zntc/core plugin onLoad loader > binary contents', () => {
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
});
