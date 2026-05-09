import {
  build,
  describe,
  expect,
  join,
  test,
  useBuildOptionsFixture,
  writeFileSync,
} from '../helpers';

describe('BuildOptions: 누락 옵션 노출 (#1005) > custom loader strictness', () => {
  const getDir = useBuildOptionsFixture();

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
