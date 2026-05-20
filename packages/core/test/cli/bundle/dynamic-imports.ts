import {
  describe,
  expect,
  join,
  mkdtempSync,
  readFileSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('CLI: bundle > dynamic import', () => {
  test('single-file bundle defaults to inlineDynamicImports', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-dynamic-import-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "export const load = () => import('./lazy').then((mod) => mod.value);",
    );
    writeFileSync(join(dir, 'lazy.ts'), 'export const value = 42;');

    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });

    expect(exitCode).toBe(0);
    expect(stdout).toContain('Promise.resolve().then');
    expect(stdout).not.toContain("import('./lazy')");
    expect(stdout).not.toContain('import("./lazy")');
    rmSync(dir, { recursive: true, force: true });
  });

  test('explicit inlineDynamicImports=false requires chunk-capable output', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-dynamic-import-off-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "export const load = () => import('./lazy').then((mod) => mod.value);",
    );
    writeFileSync(join(dir, 'lazy.ts'), 'export const value = 42;');
    writeFileSync(join(dir, 'zntc.config.ts'), 'export default { inlineDynamicImports: false };');

    const { stderr, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });

    expect(exitCode).not.toBe(0);
    expect(stderr).toContain(
      'inlineDynamicImports=false requires splitting or preserveModules in bundle mode',
    );
    rmSync(dir, { recursive: true, force: true });
  });

  test('react-native single-file bundle lowers unresolved dynamic imports for Hermes', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-rn-dynamic-import-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "export const load = () => import('external-only').then((mod) => mod.value);",
    );
    const outFile = join(dir, 'main.jsbundle');

    const { stdout, exitCode } = runCli(
      ['--bundle', join(dir, 'entry.ts'), '--platform=react-native', '--bundle-output', outFile],
      { cwd: dir },
    );
    const output = readFileSync(outFile, 'utf8');

    expect(exitCode).toBe(0);
    expect(stdout).toBe('');
    expect(output).toContain('Dynamic import is not available in this React Native bundle');
    expect(output).not.toContain("import('external-only')");
    expect(output).not.toContain('import("external-only")');
    rmSync(dir, { recursive: true, force: true });
  });
});
