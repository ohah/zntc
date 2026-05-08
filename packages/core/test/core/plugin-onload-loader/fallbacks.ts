import {
  describe,
  test,
  expect,
  build,
  resolve,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
  runBundleStdout,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core plugin onLoad loader > fallbacks', () => {
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
