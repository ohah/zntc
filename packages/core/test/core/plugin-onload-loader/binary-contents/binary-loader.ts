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

describe('@zntc/core plugin onLoad loader > binary loader', () => {
  test("loader='binary': Uint8Array default export + Node 실행 결과 일치", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-binary-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        "import bytes from './data.dat';\nconsole.log(bytes instanceof Uint8Array, bytes.length, bytes[0], bytes[1]);",
      );
      writeFileSync(join(dir, 'data.dat'), 'AB');
      const plugin: ZntcPlugin = {
        name: 'dat-as-binary',
        setup(build) {
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
