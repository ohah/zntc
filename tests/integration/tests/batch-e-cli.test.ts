import { describe, test, expect, afterEach } from 'bun:test';
import { runZntc, runZntcInDir, createFixture } from './helpers';
import { decodeMappings } from './sourcemap-helpers';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

describe('배치 E: CLI 옵션', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('--packages=external: bare import가 external 처리됨', async () => {
    const fixture = await createFixture({
      'index.ts': `import React from "react";\nimport { useState } from "react";\nconst x = 1;\nconsole.log(x);`,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, 'out.js');

    const result = await runZntc([
      '--bundle',
      join(fixture.dir, 'index.ts'),
      '-o',
      outFile,
      '--packages=external',
      '--format=esm',
    ]);

    expect(result.exitCode).toBe(0);
    const output = readFileSync(outFile, 'utf-8');
    // external이므로 react가 require/import로 보존되어야 함
    expect(output).toContain('"react"');
    expect(output).toContain('const x = 1');
  });

  test('--packages=external: 상대 경로는 번들에 포함됨', async () => {
    const fixture = await createFixture({
      'index.ts': `import { foo } from "./lib";\nconsole.log(foo);`,
      'lib.ts': `export const foo = 42;`,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, 'out.js');

    const result = await runZntc([
      '--bundle',
      join(fixture.dir, 'index.ts'),
      '-o',
      outFile,
      '--packages=external',
      '--format=esm',
    ]);

    expect(result.exitCode).toBe(0);
    const output = readFileSync(outFile, 'utf-8');
    // 상대 경로는 번들에 포함
    expect(output).toContain('42');
    // import './lib' 문은 scope hoisting으로 제거됨
    expect(output).not.toContain('from "./lib"');
  });

  test('--allow-overwrite: 알 수 없는 옵션으로 에러 안 남', async () => {
    const result = await runZntc(['--allow-overwrite', '--help']);
    // --allow-overwrite가 파싱되고 --help가 실행됨
    expect(result.exitCode).toBe(0);
  });

  test('--allow-overwrite: 기본은 입력=출력 overwrite 차단', async () => {
    const fixture = await createFixture({
      'input.ts': 'const x: number = 1;\n',
    });
    cleanup = fixture.cleanup;

    const input = join(fixture.dir, 'input.ts');
    const result = await runZntc([input, '-o', input]);

    expect(result.exitCode).toBe(1);
    expect(result.stderr).toContain('would overwrite input file');
    expect(result.stderr).toContain('--allow-overwrite');
  });

  test('--allow-overwrite: 명시 flag가 있으면 입력=출력 overwrite 허용', async () => {
    const fixture = await createFixture({
      'input.ts': 'const x: number = 1;\n',
    });
    cleanup = fixture.cleanup;

    const input = join(fixture.dir, 'input.ts');
    const result = await runZntc([input, '-o', input, '--allow-overwrite']);

    expect(result.exitCode).toBe(0);
    expect(readFileSync(input, 'utf-8')).toContain('const x = 1');
  });

  test('--allow-overwrite: 디렉토리 입력과 동일 outdir 조합은 별도 .js 출력으로 성공', async () => {
    const fixture = await createFixture({
      'src/input.ts': 'const x: number = 1;\n',
    });
    cleanup = fixture.cleanup;

    const srcDir = join(fixture.dir, 'src');
    const result = await runZntc([srcDir, '--outdir', srcDir]);

    expect(result.exitCode).toBe(0);
    expect(existsSync(join(srcDir, 'input.js'))).toBe(true);
  });

  test('--log-limit: 숫자가 아니면 에러 메시지 출력', async () => {
    const result = await runZntc(['--log-limit=abc', 'dummy.ts']);
    expect(result.stderr).toContain('--log-limit requires a number');
  });

  test('--line-limit: 숫자가 아니면 에러 메시지 출력', async () => {
    const result = await runZntc(['--line-limit=xyz', 'dummy.ts']);
    expect(result.stderr).toContain('--line-limit requires a number');
  });

  test('--line-limit: JS CLI minify 출력의 긴 라인을 wrap', async () => {
    const fixture = await createFixture({
      'index.ts': `export const values = [${Array.from({ length: 48 }, (_, i) => i).join(',')}];\nconsole.log(values.length);`,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, 'out.js');

    const result = await runZntcInDir(
      fixture.dir,
      ['--bundle', 'index.ts', '-o', outFile, '--minify', '--line-limit=40'],
      { bin: 'js' },
    );

    expect(result.exitCode).toBe(0);
    const output = readFileSync(outFile, 'utf-8');
    const maxLineLength = Math.max(
      ...output
        .trimEnd()
        .split('\n')
        .map((line) => line.length),
    );
    expect(maxLineLength).toBeLessThanOrEqual(40);
  });

  test('--line-limit: JS CLI sourcemap mappings remain decodable after wrapping', async () => {
    const fixture = await createFixture({
      'index.ts': `export const values = [${Array.from({ length: 48 }, (_, i) => i).join(',')}];\nconsole.log(values.length);`,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, 'out.js');

    const result = await runZntcInDir(
      fixture.dir,
      ['--bundle', 'index.ts', '-o', outFile, '--minify', '--line-limit=40', '--sourcemap'],
      { bin: 'js' },
    );

    expect(result.exitCode).toBe(0);
    const output = readFileSync(outFile, 'utf-8');
    const codeLines = output
      .trimEnd()
      .split('\n')
      .filter((line) => !line.startsWith('//# sourceMappingURL='));
    expect(Math.max(...codeLines.map((line) => line.length))).toBeLessThanOrEqual(40);

    const map = JSON.parse(readFileSync(outFile + '.map', 'utf-8'));
    const decoded = decodeMappings(map.mappings);
    expect(decoded.length).toBeGreaterThan(1);
    expect(decoded.some((line) => line.length > 0)).toBe(true);
  });

  test('--jsx-side-effects: 파싱됨', async () => {
    const result = await runZntc(['--jsx-side-effects', '--help']);
    expect(result.exitCode).toBe(0);
  });

  test('--ignore-annotations: 파싱됨', async () => {
    const result = await runZntc(['--ignore-annotations', '--help']);
    expect(result.exitCode).toBe(0);
  });

  test('--drop-labels: 라벨 파싱됨', async () => {
    const result = await runZntc(['--drop-labels=DEV,TEST', '--help']);
    expect(result.exitCode).toBe(0);
  });

  test('--pure: 파싱됨', async () => {
    const result = await runZntc(['--pure:console.log', '--help']);
    expect(result.exitCode).toBe(0);
  });

  test('--tsconfig-raw: 파싱됨', async () => {
    const result = await runZntc(['--tsconfig-raw={}', '--help']);
    expect(result.exitCode).toBe(0);
  });

  test('--node-paths: 파싱됨', async () => {
    const result = await runZntc(['--node-paths=/usr/lib/node', '--help']);
    expect(result.exitCode).toBe(0);
  });

  test('--watch-delay: 파싱됨', async () => {
    const result = await runZntc(['--watch-delay=200', '--help']);
    expect(result.exitCode).toBe(0);
  });

  test('--watch-delay: 숫자가 아니면 에러 메시지 출력', async () => {
    const result = await runZntc(['--watch-delay=slow', 'dummy.ts']);
    expect(result.stderr).toContain('--watch-delay requires a number');
  });

  test('--clean: 파싱됨', async () => {
    const result = await runZntc(['--clean', '--help']);
    expect(result.exitCode).toBe(0);
  });

  test('--outbase: 파싱됨', async () => {
    const result = await runZntc(['--outbase=src', '--help']);
    expect(result.exitCode).toBe(0);
  });
});
