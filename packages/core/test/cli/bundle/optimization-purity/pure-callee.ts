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

describe('CLI: bundle purity optimization flags > pure callees', () => {
  test('번들 + --pure:<callee> 미사용 call 제거', () => {
    const pureDir = mkdtempSync(join(tmpdir(), 'zntc-cli-pure-'));
    try {
      writeFileSync(
        join(pureDir, 'entry.ts'),
        [
          'const used = makeUsed("CLI_PURE_USED");',
          'const unused = makeUnused("CLI_PURE_UNUSED");',
          'const el = React.createElement("div", { title: "CLI_PURE_REACT" });',
          'const prop = PropTypes.string.isRequired("CLI_PURE_WILDCARD");',
          'React.cloneElement("CLI_PURE_NONMATCH");',
          'console.log(used);',
        ].join('\n'),
      );
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(pureDir, 'entry.ts'),
        '--minify-syntax',
        '--pure:makeUnused',
        '--pure:React.createElement',
        '--pure:PropTypes.*',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('CLI_PURE_USED');
      expect(stdout).not.toContain('CLI_PURE_UNUSED');
      expect(stdout).not.toContain('CLI_PURE_REACT');
      expect(stdout).not.toContain('CLI_PURE_WILDCARD');
      expect(stdout).toContain('CLI_PURE_NONMATCH');
    } finally {
      rmSync(pureDir, { recursive: true, force: true });
    }
  });
});
