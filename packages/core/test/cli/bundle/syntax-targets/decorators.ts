import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  rmSync,
  tmpdir,
  join,
  runCli,
} from '../../helpers';

describe('CLI: bundle syntax and targets > decorators', () => {
  test('--emit-decorator-metadata + --experimental-decorators', () => {
    const decDir = mkdtempSync(join(tmpdir(), 'zntc-cli-decorator-'));
    try {
      writeFileSync(
        join(decDir, 'entry.ts'),
        "function dec(t: unknown, k: string) {} class C { @dec method(): string { return 'OK'; } } console.log('ok');",
      );
      const { exitCode } = runCli([
        '--bundle',
        join(decDir, 'entry.ts'),
        '--experimental-decorators',
        '--emit-decorator-metadata',
      ]);
      expect(exitCode).toBe(0);
    } finally {
      rmSync(decDir, { recursive: true, force: true });
    }
  });
});
