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
import { useTranspileFixture } from './fixture';

describe('CLI: transpile', () => {
  const fixture = useTranspileFixture();

  test('--allow-overwrite 미지정 시 입력=출력 차단', () => {
    const outFile = fixture.path('input.ts');
    const { exitCode, stderr } = runCli([fixture.path('input.ts'), '-o', outFile]);
    expect(exitCode).toBe(1);
    expect(stderr).toContain('would overwrite input file');
    expect(stderr).toContain('--allow-overwrite');
  });

  test('--allow-overwrite 지정 시 입력=출력 허용', () => {
    const overwriteDir = mkdtempSync(join(tmpdir(), 'zntc-cli-overwrite-'));
    try {
      const file = join(overwriteDir, 'input.ts');
      writeFileSync(file, 'const x: number = 1;\n');
      const { exitCode, stderr } = runCli([file, '-o', file, '--allow-overwrite']);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('would overwrite');
      expect(readFileSync(file, 'utf8')).toContain('const x = 1');
    } finally {
      rmSync(overwriteDir, { recursive: true, force: true });
    }
  });

  test('--allow-overwrite 미지정 시 --outdir 의 동일 JS 입력 overwrite 차단', () => {
    const overwriteDir = mkdtempSync(join(tmpdir(), 'zntc-cli-overwrite-outdir-'));
    try {
      const file = join(overwriteDir, 'input.js');
      writeFileSync(file, 'const x = 1;\n');
      const { exitCode, stderr } = runCli([file, '--outdir', overwriteDir]);
      expect(exitCode).toBe(1);
      expect(stderr).toContain('would overwrite input file');
    } finally {
      rmSync(overwriteDir, { recursive: true, force: true });
    }
  });
});
