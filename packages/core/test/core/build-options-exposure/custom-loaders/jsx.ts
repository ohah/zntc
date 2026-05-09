import {
  build,
  describe,
  expect,
  join,
  runBundleStdout,
  test,
  useBuildOptionsFixture,
  writeFileSync,
} from '../helpers';

describe('BuildOptions: 누락 옵션 노출 (#1005) > custom JSX loaders', () => {
  const getDir = useBuildOptionsFixture();

  test('loader: .foo=tsx → 커스텀 확장자에서 TSX를 파싱', async () => {
    const dir = getDir();
    writeFileSync(
      join(dir, 'entry-loader-tsx.ts'),
      'import { value } from "./view.foo";\nconsole.log(value);',
    );
    writeFileSync(
      join(dir, 'view.foo'),
      'const h = (tag: string) => tag;\nexport const value: string = <div />;',
    );
    const result = await build({
      entryPoints: [join(dir, 'entry-loader-tsx.ts')],
      loader: { '.foo': 'tsx' },
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('<div');
    expect(result.outputFiles[0].text).not.toContain(': string');
    expect(await runBundleStdout(result.outputFiles[0].text)).toBe('div');
  });

  test('loader: .foo=jsx → 커스텀 확장자에서 JSX를 파싱', async () => {
    const dir = getDir();
    writeFileSync(
      join(dir, 'entry-loader-jsx.ts'),
      'import { value } from "./view-jsx.foo";\nconsole.log(value);',
    );
    writeFileSync(
      join(dir, 'view-jsx.foo'),
      'const h = (tag) => tag;\nexport const value = <span />;',
    );
    const result = await build({
      entryPoints: [join(dir, 'entry-loader-jsx.ts')],
      loader: { '.foo': 'jsx' },
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('<span');
    expect(await runBundleStdout(result.outputFiles[0].text)).toBe('span');
  });
});
