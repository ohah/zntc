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

describe('@zntc/core buildSync - graph pre-pass transform-required cases', () => {
  test('graph pre-pass keep: JSX and decorator/downlevel helper cases still transform', () => {
    const keepDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-keep-transform-'));
    try {
      writeFileSync(join(keepDir, 'jsx.tsx'), 'export const App = () => <div>ok</div>;');
      writeFileSync(join(keepDir, 'decorator.ts'), '@sealed\nexport class Box { value = 1; }');
      writeFileSync(
        join(keepDir, 'downlevel.ts'),
        'export const fn = async () => await Promise.resolve(1);',
      );

      const jsxResult = buildSync({
        entryPoints: [join(keepDir, 'jsx.tsx')],
        jsx: 'automatic',
        external: ['react/jsx-runtime'],
      });
      expect(jsxResult.errors.length).toBe(0);
      expect(jsxResult.outputFiles[0].text).toContain('jsx-runtime');

      const decoratorResult = buildSync({
        entryPoints: [join(keepDir, 'decorator.ts')],
        experimentalDecorators: true,
      });
      expect(decoratorResult.errors.length).toBe(0);
      expect(decoratorResult.outputFiles[0].text).toContain('__decorate');

      const downlevelResult = buildSync({
        entryPoints: [join(keepDir, 'downlevel.ts')],
        target: 'es5',
      });
      expect(downlevelResult.errors.length).toBe(0);
      expect(downlevelResult.outputFiles[0].text).toContain('__async');
    } finally {
      rmSync(keepDir, { recursive: true, force: true });
    }
  });
});
