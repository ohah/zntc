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
} from './helpers';

describe('@zntc/core buildSync - graph pre-pass', () => {
  test('graph pre-pass skip: no-op ESM/TS bundle still folds numeric const imports', () => {
    const skipDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-skip-esm-'));
    writeFileSync(join(skipDir, 'dep.ts'), 'export const value: number = 41;');
    writeFileSync(
      join(skipDir, 'app.ts'),
      'import { value } from "./dep";\nexport const answer: number = value + 1;',
    );
    const result = buildSync({ entryPoints: [join(skipDir, 'app.ts')] });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('answer');
    expect(result.outputFiles[0].text).toContain('42');
    expect(result.outputFiles[0].text).not.toContain('value');
    expect(result.outputFiles[0].text).not.toContain(': number');
    rmSync(skipDir, { recursive: true, force: true });
  });

  test('graph pre-pass skip: target downlevel without helper syntax stays stable', () => {
    const skipDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-skip-target-'));
    writeFileSync(
      join(skipDir, 'app.ts'),
      'export const value: number = 1;\nconsole.log("TARGET_SIMPLE_KEPT", value);',
    );
    const result = buildSync({
      entryPoints: [join(skipDir, 'app.ts')],
      target: 'es5',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('TARGET_SIMPLE_KEPT');
    expect(result.outputFiles[0].text).not.toContain(': number');
    expect(result.outputFiles[0].text).not.toContain('__async');
    expect(result.outputFiles[0].text).not.toContain('__spreadArray');
    rmSync(skipDir, { recursive: true, force: true });
  });

  test('graph pre-pass skip: type-only imports do not pull runtime modules', () => {
    const skipDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-skip-type-only-'));
    writeFileSync(
      join(skipDir, 'types.ts'),
      'console.log("TYPE_ONLY_MODULE_SHOULD_NOT_APPEAR"); export interface User { id: string }',
    );
    writeFileSync(join(skipDir, 'value.ts'), 'export const value = "TYPE_ONLY_VALUE_KEPT";');
    writeFileSync(
      join(skipDir, 'app.ts'),
      'import type { User } from "./types";\nimport { value } from "./value";\nexport const user: User = { id: value };',
    );
    const result = buildSync({ entryPoints: [join(skipDir, 'app.ts')] });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('TYPE_ONLY_VALUE_KEPT');
    expect(result.outputFiles[0].text).not.toContain('TYPE_ONLY_MODULE_SHOULD_NOT_APPEAR');
    rmSync(skipDir, { recursive: true, force: true });
  });

  test('graph pre-pass skip: re-export and namespace access stay linked', () => {
    const skipDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-skip-reexport-'));
    writeFileSync(join(skipDir, 'dep.ts'), 'export const value = "REEXPORT_NAMESPACE_VALUE";');
    writeFileSync(join(skipDir, 'barrel.ts'), 'export { value } from "./dep";');
    writeFileSync(
      join(skipDir, 'app.ts'),
      'import * as ns from "./barrel";\nconsole.log(ns.value);',
    );
    const result = buildSync({ entryPoints: [join(skipDir, 'app.ts')] });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('REEXPORT_NAMESPACE_VALUE');
    expect(result.outputFiles[0].text).toContain('value');
    rmSync(skipDir, { recursive: true, force: true });
  });

  test('graph pre-pass keep: JSX and decorator/downlevel helper cases still transform', () => {
    const keepDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-keep-transform-'));
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
    rmSync(keepDir, { recursive: true, force: true });
  });
});
