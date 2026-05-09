import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from '../helpers';

describe('CLI: import.meta.glob > basic options', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-cli-glob-'));
    mkdirSync(join(dir, 'modules'), { recursive: true });
    writeFileSync(join(dir, 'modules', 'a.ts'), 'export const setup = () => "a";');
    writeFileSync(join(dir, 'modules', 'b.ts'), 'export const setup = () => "b";');
    writeFileSync(join(dir, 'modules', 'c.ts'), 'export default 42;');
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('lazy (default): () => import() 패턴', () => {
    writeFileSync(
      join(dir, 'lazy.ts'),
      'const m = import.meta.glob("./modules/*.ts");\nconsole.log(m);',
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'lazy.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('() => import(');
    expect(stdout).toContain('./modules/a.ts');
    expect(stdout).not.toContain('await import(');
  });

  test('eager: await import() 패턴', () => {
    writeFileSync(
      join(dir, 'eager.ts'),
      'const m = import.meta.glob("./modules/*.ts", { eager: true });\nconsole.log(m);',
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'eager.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('await import(');
    expect(stdout).not.toContain('() => import(');
  });

  test('import option: .then(m => m.setup) 패턴', () => {
    writeFileSync(
      join(dir, 'named.ts'),
      'const m = import.meta.glob("./modules/*.ts", { import: "setup" });\nconsole.log(m);',
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'named.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('m.setup');
    expect(stdout).toContain('() => import(');
  });

  test('eager + import: (await import()).setup 패턴', () => {
    writeFileSync(
      join(dir, 'eager-named.ts'),
      'const m = import.meta.glob("./modules/*.ts", { eager: true, import: "setup" });\nconsole.log(m);',
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'eager-named.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('(await import(');
    expect(stdout).toContain(').setup');
  });
});
