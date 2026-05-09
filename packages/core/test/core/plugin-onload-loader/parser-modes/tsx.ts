import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  runBundleStdout,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

describe('@zntc/core plugin onLoad loader > TSX parser mode', () => {
  test("loader='tsx': onLoad contents를 TSX parser mode로 처리", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-tsx-'));
    try {
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
