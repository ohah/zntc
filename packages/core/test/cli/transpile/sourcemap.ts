import { describe, existsSync, expect, join, readFileSync, runCli, test } from '../helpers';
import { useTranspileFixture } from './fixture';

describe('CLI: transpile 소스맵', () => {
  const fixture = useTranspileFixture();

  test('-o + --sourcemap → .map 과 sourceMappingURL 주석', () => {
    const outFile = fixture.path('sm-linked.js');
    const { exitCode } = runCli([fixture.path('input.ts'), '-o', outFile, '--sourcemap']);
    expect(exitCode).toBe(0);
    expect(existsSync(outFile + '.map')).toBe(true);
    // 주석이 없으면 브라우저가 맵을 아예 찾지 않는다
    expect(readFileSync(outFile, 'utf8')).toContain('//# sourceMappingURL=sm-linked.js.map');
  });

  test('맵의 sources 는 맵이 놓인 자리 기준, file 은 생성 파일', () => {
    const outDir = fixture.path('sm-out');
    const { exitCode } = runCli([fixture.path('input.ts'), '--outdir', outDir, '--sourcemap']);
    expect(exitCode).toBe(0);
    const map = JSON.parse(readFileSync(join(outDir, 'input.js.map'), 'utf8'));
    expect(map.file).toBe('input.js');
    // CWD 기준이면 브라우저가 outdir/<원본경로> 를 찾다 못 찾는다
    expect(map.sources[0]).toBe('../input.ts');
  });

  test('--outdir 에서도 맵이 나온다', () => {
    const outDir = fixture.path('sm-outdir');
    const { exitCode } = runCli([fixture.path('input.ts'), '--outdir', outDir, '--sourcemap']);
    expect(exitCode).toBe(0);
    expect(existsSync(join(outDir, 'input.js.map'))).toBe(true);
    expect(readFileSync(join(outDir, 'input.js'), 'utf8')).toContain(
      '//# sourceMappingURL=input.js.map',
    );
  });

  test('--sourcemap=external → 맵만, 주석 없음', () => {
    const outFile = fixture.path('sm-external.js');
    const { exitCode } = runCli([fixture.path('input.ts'), '-o', outFile, '--sourcemap=external']);
    expect(exitCode).toBe(0);
    expect(existsSync(outFile + '.map')).toBe(true);
    expect(readFileSync(outFile, 'utf8')).not.toContain('sourceMappingURL');
  });

  test('--sourcemap=inline → 맵 파일 없이 data URL 로 심는다', () => {
    const outFile = fixture.path('sm-inline.js');
    const { exitCode } = runCli([fixture.path('input.ts'), '-o', outFile, '--sourcemap=inline']);
    expect(exitCode).toBe(0);
    expect(existsSync(outFile + '.map')).toBe(false);
    expect(readFileSync(outFile, 'utf8')).toContain(
      '//# sourceMappingURL=data:application/json;base64,',
    );
  });
});
