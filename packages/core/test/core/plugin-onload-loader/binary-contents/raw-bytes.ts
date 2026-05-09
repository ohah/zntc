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

describe('@zntc/core plugin onLoad loader > raw byte contents', () => {
  test('contents=Uint8Array (binary safe): 비-utf8 bytes 도 손실 없이 forward (#2157 follow-up)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-uint8-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        "import bytes from './data.bin';\nconsole.log(bytes.length, bytes[0], bytes[1], bytes[2], bytes[3]);",
      );
      const rawBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
      writeFileSync(join(dir, 'data.bin'), rawBytes);
      const plugin: ZntcPlugin = {
        name: 'bin-as-binary-uint8',
        setup(build) {
          build.onResolve({ filter: /\.bin$/ }, (args) => ({ path: resolve(dir, args.path) }));
          build.onLoad({ filter: /\.bin$/ }, (args) => ({
            contents: readFileSync(args.path),
            loader: 'binary',
          }));
        },
      };
      const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
      expect(r.outputFiles[0].text).toContain('__toBinary');
      expect(await runBundleStdout(r.outputFiles[0].text)).toBe('4 137 80 78 71');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
