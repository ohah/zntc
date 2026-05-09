import {
  describe,
  test,
  expect,
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  tmpdir,
  join,
  runCli,
} from '../../helpers';

describe('CLI: zntc.config merge priority > tsconfig/config/CLI', () => {
  test('tsconfig + config + CLI 3-way 우선순위: CLI > config > tsconfig', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-3way-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { jsx: 'preserve' } }),
    );
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ jsx: 'automatic' }));
    writeFileSync(join(dir, 'src', 'App.tsx'), 'export default () => <div>Hello</div>;');
    const { stdout, exitCode } = runCli(
      ['--bundle', '--jsx=transform', join(dir, 'src', 'App.tsx')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('React.createElement');
    expect(stdout).not.toContain('jsx-runtime');
    expect(stdout).not.toContain('<div>');
    rmSync(dir, { recursive: true, force: true });
  });
});
