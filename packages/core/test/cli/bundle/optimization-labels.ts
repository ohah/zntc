import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  tmpdir,
  join,
  runCli,
} from '../helpers';

describe('CLI: bundle label optimization flags', () => {
  test('번들 + --drop-labels=DEV,TEST 라벨 블록 제거', () => {
    const labelDir = mkdtempSync(join(tmpdir(), 'zntc-cli-drop-labels-'));
    try {
      writeFileSync(
        join(labelDir, 'entry.ts'),
        [
          'DEV: { console.log("dev-only"); }',
          'TEST: { console.log("test-only"); }',
          'OUTER: { DEV: { console.log("nested-dev"); } console.log("outer"); }',
          'KEEP: { console.log("keep"); }',
          'console.log("done");',
        ].join('\n'),
      );
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(labelDir, 'entry.ts'),
        '--drop-labels=DEV,TEST',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).not.toContain('dev-only');
      expect(stdout).not.toContain('test-only');
      expect(stdout).not.toContain('nested-dev');
      expect(stdout).toContain('outer');
      expect(stdout).toContain('keep');
      expect(stdout).toContain('done');
    } finally {
      rmSync(labelDir, { recursive: true, force: true });
    }
  });

  test('번들 + --drop-labels + --sourcemap 출력', () => {
    const labelDir = mkdtempSync(join(tmpdir(), 'zntc-cli-drop-labels-sourcemap-'));
    try {
      const entry = join(labelDir, 'entry.ts');
      const outFile = join(labelDir, 'bundle.js');
      writeFileSync(entry, 'DEV: { console.log("dev-only"); }\nconsole.log("live");\n');
      const { exitCode } = runCli([
        '--bundle',
        entry,
        '--drop-labels=DEV',
        '--sourcemap',
        '-o',
        outFile,
      ]);
      expect(exitCode).toBe(0);
      const output = readFileSync(outFile, 'utf8');
      const map = readFileSync(outFile + '.map', 'utf8');
      expect(output).not.toContain('dev-only');
      expect(output).toContain('live');
      expect(map).toContain('"mappings"');
      expect(map).toContain('entry.ts');
    } finally {
      rmSync(labelDir, { recursive: true, force: true });
    }
  });
});
