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

describe('BuildOptions: 누락 옵션 노출 (#1005) > custom TypeScript loaders', () => {
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
});
