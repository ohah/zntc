import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  readFileSync,
  resolve,
  rmSync,
  runBundleStdout,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core plugin onLoad loader > dataurl and Buffer contents', () => {
  test("contents=Uint8Array + loader='dataurl' (PNG raw bytes 보존)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-png-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), "import url from './tiny.png';\nconsole.log(url);");
      const rawBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
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
      expect(await runBundleStdout(r.outputFiles[0].text)).toBe('data:image/png;base64,iVBORw==');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('contents=Buffer (Node Buffer): napi_is_buffer 경로로 raw bytes forward', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-buffer-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        "import bytes from './data.raw';\nconsole.log(bytes.length, bytes[0], bytes[1]);",
      );
      const plugin: ZntcPlugin = {
        name: 'raw-as-buffer',
        setup(build) {
          build.onResolve({ filter: /\.raw$/ }, (args) => ({ path: resolve(dir, args.path) }));
          build.onLoad({ filter: /\.raw$/ }, () => ({
            contents: Buffer.from([0xff, 0xfe]),
            loader: 'binary',
          }));
        },
      };
      const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
      expect(await runBundleStdout(r.outputFiles[0].text)).toBe('2 255 254');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
