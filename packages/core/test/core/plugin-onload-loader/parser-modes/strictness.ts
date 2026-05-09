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

async function runOnLoadCase(loader: 'js' | 'jsx' | 'ts' | 'tsx', contents: string) {
  const dir = mkdtempSync(join(tmpdir(), `zntc-onload-${loader}-strict-`));
  try {
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
    return await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [plugin],
      jsx: 'classic',
      jsxFactory: 'h',
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe('@zntc/core plugin onLoad loader > parser mode strictness', () => {
  test("loader='js'/'jsx'/'ts'/'tsx': onLoad parser mode strictness", async () => {
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
