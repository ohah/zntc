import {
  describe,
  test,
  expect,
  build,
  writeFileSync,
  join,
  runBundleStdout,
  useBuildOptionsFixture,
} from './helpers';

describe('BuildOptions: 누락 옵션 노출 (#1005) > custom extension loaders', () => {
  const getDir = useBuildOptionsFixture();

  test('loader: .foo=ts → 커스텀 확장자를 TypeScript로 파싱', async () => {
    const dir = getDir();
    writeFileSync(
      join(dir, 'entry-loader-ts.ts'),
      'import { value } from "./value.foo";\nconsole.log(value);',
    );
    writeFileSync(join(dir, 'value.foo'), 'export const value: number = 1;');
    const result = await build({
      entryPoints: [join(dir, 'entry-loader-ts.ts')],
      loader: { '.foo': 'ts' },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain(': number');
    expect(await runBundleStdout(result.outputFiles[0].text)).toBe('1');
  });

  test('loader: .foo=ts → JSX syntax를 거부', async () => {
    const dir = getDir();
    writeFileSync(
      join(dir, 'entry-loader-ts-no-jsx.ts'),
      'import { value } from "./view-ts-no-jsx.foo";\nconsole.log(value);',
    );
    writeFileSync(
      join(dir, 'view-ts-no-jsx.foo'),
      'const h = (tag) => tag;\nexport const value = <div />;',
    );
    const result = await build({
      entryPoints: [join(dir, 'entry-loader-ts-no-jsx.ts')],
      loader: { '.foo': 'ts' },
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(result.errors.length).toBeGreaterThan(0);
  });

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

  test('loader: .foo=js/jsx → TypeScript syntax를 거부', async () => {
    const dir = getDir();
    writeFileSync(
      join(dir, 'entry-loader-js-strict.ts'),
      'import { value } from "./value-js-strict.foo";\nconsole.log(value);',
    );
    writeFileSync(join(dir, 'value-js-strict.foo'), 'export const value: number = 1;');
    const jsResult = await build({
      entryPoints: [join(dir, 'entry-loader-js-strict.ts')],
      loader: { '.foo': 'js' },
    });
    expect(jsResult.errors.length).toBeGreaterThan(0);
    expect(jsResult.errors[0].text).toContain('TypeScript');

    writeFileSync(
      join(dir, 'entry-loader-jsx-strict.ts'),
      'import { value } from "./value-jsx-strict.foo";\nconsole.log(value);',
    );
    writeFileSync(
      join(dir, 'value-jsx-strict.foo'),
      'const h = (tag) => tag;\nexport const value: string = <span />;',
    );
    const jsxResult = await build({
      entryPoints: [join(dir, 'entry-loader-jsx-strict.ts')],
      loader: { '.foo': 'jsx' },
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(jsxResult.errors.length).toBeGreaterThan(0);
    expect(jsxResult.errors[0].text).toContain('TypeScript');
  });
});
