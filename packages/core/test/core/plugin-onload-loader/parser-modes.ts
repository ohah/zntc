import {
  describe,
  test,
  expect,
  build,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
  runBundleStdout,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core plugin onLoad loader > parser modes', () => {
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
});
