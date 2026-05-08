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

describe('CLI: zntc.config BuildOptions', () => {
  test('zntc.config.ts 의 minify 가 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-minify-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'const someLongName = 1; const anotherLongName = 2; console.log(someLongName + anotherLongName);',
    );
    writeFileSync(join(dir, 'zntc.config.ts'), `export default { minify: true };`);
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('someLongName');
    rmSync(dir, { recursive: true, force: true });
  });

  test('zntc.config.json 의 runtimePolyfills 가 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-runtime-polyfills-'));
    writeFileSync(join(dir, 'entry.ts'), `globalThis.__VALUE__ = "a".replaceAll("a", "b");`);
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({
        entryPoints: ['./entry.ts'],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
      }),
    );
    const { stdout, stderr, exitCode } = runCli(['--bundle'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toBe('');
    expect(stdout).toContain('es.string.replace-all');
    rmSync(dir, { recursive: true, force: true });
  });

  test('zntc.config.json 의 external 배열이 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-external-'));
    writeFileSync(join(dir, 'entry.ts'), 'import * as fs from "node:fs";\nconsole.log(fs);');
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ external: ['node:fs'] }));
    const { stdout, stderr, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toMatch(/node:fs|require.*fs/);
    expect(stderr).not.toContain('error');
    rmSync(dir, { recursive: true, force: true });
  });

  test('zntc.config.json 의 packagesExternal 이 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-packages-external-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        'import React from "react";\nimport { local } from "./local";\nconsole.log(React, local);',
      );
      writeFileSync(join(dir, 'local.ts'), "export const local = 'CONFIG_LOCAL_INCLUDED';");
      writeFileSync(
        join(dir, 'zntc.config.json'),
        JSON.stringify({ entryPoints: ['./entry.ts'], packagesExternal: true, format: 'esm' }),
      );
      const { stdout, stderr, exitCode } = runCli(['--bundle'], { cwd: dir });
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('error');
      expect(stdout).toContain('"react"');
      expect(stdout).toContain('CONFIG_LOCAL_INCLUDED');
      expect(stdout).not.toContain('from "./local"');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('config 의 format 머지 — CLI 미지정 시 적용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-format-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ format: 'iife', globalName: 'G' }),
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('var G');
    rmSync(dir, { recursive: true, force: true });
  });

  test('config 의 target 머지 — CLI 미지정 시 적용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-target-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'const arr = [1, 2, 3];\nconst [a, ...rest] = arr;\nconsole.log(a, rest);',
    );
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ target: 'es5' }));
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('.slice(');
    rmSync(dir, { recursive: true, force: true });
  });
});
