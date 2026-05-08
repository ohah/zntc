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
} from '../helpers';

describe('CLI: bundle purity optimization flags', () => {
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

  test('번들 + --jsx-side-effects preserves unused JSX expression', () => {
    const jsxDir = mkdtempSync(join(tmpdir(), 'zntc-cli-jsx-side-effects-'));
    try {
      writeFileSync(
        join(jsxDir, 'entry.tsx'),
        [
          'const React = { createElement(type) { console.log(type); } };',
          '<div />;',
          "console.log('live');",
        ].join('\n'),
      );
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(jsxDir, 'entry.tsx'),
        '--minify-syntax',
        '--jsx-side-effects',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('React.createElement');
    } finally {
      rmSync(jsxDir, { recursive: true, force: true });
    }
  });

  test('번들 + --ignore-annotations preserves @__PURE__ call', () => {
    const annDir = mkdtempSync(join(tmpdir(), 'zntc-cli-ignore-annotations-'));
    try {
      writeFileSync(
        join(annDir, 'entry.ts'),
        "function side(){ console.log('PURE_CALL'); }\n/* @__PURE__ */ side();\nconsole.log('live');",
      );
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(annDir, 'entry.ts'),
        '--minify-syntax',
        '--ignore-annotations',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('side()');
      expect(stdout).toContain('PURE_CALL');
    } finally {
      rmSync(annDir, { recursive: true, force: true });
    }
  });
});
