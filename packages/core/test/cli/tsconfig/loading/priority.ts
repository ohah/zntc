import {
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../../helpers';

describe('CLI: tsconfig loading > option priority', () => {
  test('CLI 옵션이 tsconfig보다 우선', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-override-'));
    try {
      writeFileSync(
        join(dir, 'tsconfig.json'),
        JSON.stringify({ compilerOptions: { jsx: 'react' } }),
      );
      writeFileSync(join(dir, 'app.tsx'), 'export default () => <div>hello</div>;');

      const { stdout, exitCode } = runCli([join(dir, 'app.tsx'), '--jsx=automatic']);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('jsx');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
