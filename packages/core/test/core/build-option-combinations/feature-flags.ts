import {
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('@zntc/core build 옵션 조합 - feature flags', () => {
  test('treeShaking=false로 미사용 export 보존', () => {
    const tsDir = mkdtempSync(join(tmpdir(), 'zntc-tree-'));
    writeFileSync(join(tsDir, 'index.ts'), 'import { used } from "./lib";\nconsole.log(used);');
    writeFileSync(join(tsDir, 'lib.ts'), 'export const used = 1;\nexport const unused = 2;');

    const withTree = buildSync({
      entryPoints: [join(tsDir, 'index.ts')],
      treeShaking: true,
    });
    const withoutTree = buildSync({
      entryPoints: [join(tsDir, 'index.ts')],
      treeShaking: false,
    });
    expect(withoutTree.outputFiles[0].text).toContain('unused');
    expect(withTree.outputFiles[0].text).not.toContain('unused');
    rmSync(tsDir, { recursive: true, force: true });
  });

  test('JSX automatic + build', () => {
    const jsxDir = mkdtempSync(join(tmpdir(), 'zntc-jsx-build-'));
    writeFileSync(join(jsxDir, 'app.tsx'), 'export default () => <div>hello</div>;');

    const result = buildSync({
      entryPoints: [join(jsxDir, 'app.tsx')],
      jsx: 'automatic',
      jsxInJs: true,
      external: ['react/jsx-runtime'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('jsx-runtime');
    rmSync(jsxDir, { recursive: true, force: true });
  });

  test('Flow 파일 번들링', () => {
    const flowDir = mkdtempSync(join(tmpdir(), 'zntc-flow-build-'));
    writeFileSync(
      join(flowDir, 'index.js'),
      '// @flow\nfunction foo(x: string): number { return x.length; }\nconsole.log(foo("test"));',
    );

    const result = buildSync({
      entryPoints: [join(flowDir, 'index.js')],
      flow: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain(': string');
    expect(result.outputFiles[0].text).not.toContain(': number');
    rmSync(flowDir, { recursive: true, force: true });
  });
});
