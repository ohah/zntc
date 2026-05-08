import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  rmSync,
  existsSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from './helpers';

describe('CLI: zntc.config 자동 탐색 + BuildOptions 머지', () => {
  test('zntc.config.ts 의 entryPoints 가 자동 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-merge-'));
    writeFileSync(join(dir, 'src.ts'), "export const HIT = 'CONFIG_ENTRY_OK';");
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      `export default { entryPoints: ["${join(dir, 'src.ts').replace(/\\/g, '/')}"] };`,
    );
    // CLI 에 entry 안 줬는데 config 의 entryPoints 로 빌드되어야 함.
    const { stdout, exitCode } = runCli(['--bundle'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('CONFIG_ENTRY_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('zntc.config.json 의 outdir 이 자동 적용됨 (단일 build, CLI --outdir 미지정)', () => {
    // 회귀 테스트: parseArgs 의 outfile/outdir 기본값이 `null` 이라서 mergeConfigIntoOpts
    // 의 `=== undefined` 머지 조건을 우회 못 해 config.outdir 이 silent drop 되던 버그.
    // workspace 흐름은 buildSubOpts 에서 보강했지만 단일 build 경로는 깨져 있었음.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-outdir-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('SINGLE_OUTDIR_OK');");
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ entryPoints: ['./entry.ts'], outdir: './dist' }),
    );
    const { stdout, exitCode } = runCli(['--bundle'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('SINGLE_OUTDIR_OK'); // stdout 으로 빠지면 안 됨
    expect(existsSync(join(dir, 'dist'))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });

  test('zntc.config.json 의 outfile 이 자동 적용됨 (단일 build, CLI --outfile 미지정)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-outfile-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('SINGLE_OUTFILE_OK');");
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ entryPoints: ['./entry.ts'], outfile: './out.js' }),
    );
    const { stdout, exitCode } = runCli(['--bundle'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('SINGLE_OUTFILE_OK');
    expect(existsSync(join(dir, 'out.js'))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });

  test('CLI --outdir 이 config.outdir 을 override', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-outdir-override-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ entryPoints: ['./entry.ts'], outdir: './from-config' }),
    );
    const { exitCode } = runCli(['--bundle', '--outdir', './from-cli'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(existsSync(join(dir, 'from-cli'))).toBe(true);
    expect(existsSync(join(dir, 'from-config'))).toBe(false);
    rmSync(dir, { recursive: true, force: true });
  });

  test('zntc.config.ts 의 minify 가 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-minify-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'const someLongName = 1; const anotherLongName = 2; console.log(someLongName + anotherLongName);',
    );
    writeFileSync(join(dir, 'zntc.config.ts'), `export default { minify: true };`);
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    // minify 시 식별자 축약으로 someLongName 같은 긴 이름이 사라짐.
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

  test('CLI 가 config 를 override (CLI > config 우선순위)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-override-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('cli_wins');");
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ format: 'iife', globalName: 'CFG_NAME' }),
    );
    // CLI 가 globalName 을 다른 값으로 넘기면 그게 우선.
    const { stdout, exitCode } = runCli(
      ['--bundle', '--global-name=CLI_NAME', join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('CLI_NAME');
    expect(stdout).not.toContain('CFG_NAME');
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
    // external 이면 require/import 가 그대로 보존됨.
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

  test('zntc.config.ts 의 plugins 가 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-plugins-'));
    writeFileSync(join(dir, 'entry.ts'), 'import x from "virtual:hello";\nconsole.log(x);');
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      `export default {
         plugins: [{
           name: "virtual",
           setup(build) {
             build.onResolve({ filter: /^virtual:/ }, (args) => ({ path: args.path, namespace: "virtual" }));
             build.onLoad({ filter: /.*/, namespace: "virtual" }, () => ({ contents: 'export default "PLUGIN_OK";' }));
           },
         }],
       };`,
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('PLUGIN_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('config 부재 시 CLI 단독으로 정상 빌드 (회귀 방지)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-no-config-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('NO_CONFIG_OK');");
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('NO_CONFIG_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('config 컴파일 실패 시 CLI 가 명확한 에러로 exit 1', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-broken-config-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('x');");
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      "export default { format: 'esm'  // 닫는 brace 없음",
    );
    const { stderr, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(1);
    expect(stderr).toContain('failed to load config');
    rmSync(dir, { recursive: true, force: true });
  });

  test('--plugin <path> 의 plugins 필드가 적용된다 (BuildOptions 다른 필드는 무시)', () => {
    // `--plugin <path>` 는 의미상 plugin-only 진입점 — 자동 탐색의 BuildOptions
    // 머지와 분리. config 의 BuildOptions 적용은 자동 탐색 경로 (zntc.config.*) 가
    // 담당. `--config <path>` 로 명시적으로 BuildOptions 머지하는 경로는 #2103.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-only-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('original');");
    writeFileSync(
      join(dir, 'p.js'),
      `export default {
         plugins: [{
           name: "marker",
           setup(build) {
             build.onLoad({ filter: /entry\\.ts$/ }, () => ({ contents: 'console.log("MARKER_OK");' }));
           },
         }],
       };`,
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', '--plugin', join(dir, 'p.js'), join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('MARKER_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  // ─ 백필: Phase 1-2 (#2115) BuildOptions 머지 갭 ───────────────────────────────

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

  test('config 의 sourcemap=true 가 적용됨 (default=false override)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-sourcemap-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ sourcemap: true }));
    const outFile = join(dir, 'out.js');
    const { exitCode } = runCli(['--bundle', '-o', outFile, join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(existsSync(outFile + '.map')).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });

  test('config 의 alias 객체 머지 — CLI alias 가 키 단위로 override', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-alias-'));
    writeFileSync(join(dir, 'real-a.ts'), "export const tag = 'CONFIG_ALIAS_A';");
    writeFileSync(join(dir, 'real-b.ts'), "export const tag = 'CLI_ALIAS_B';");
    writeFileSync(
      join(dir, 'entry.ts'),
      `import { tag as a } from "@a";
       import { tag as b } from "@b";
       console.log(a, b);`,
    );
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({
        alias: {
          '@a': join(dir, 'real-a.ts'),
          '@b': join(dir, 'should-be-overridden.ts'),
        },
      }),
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', `--alias:@b=${join(dir, 'real-b.ts')}`, join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('CONFIG_ALIAS_A'); // config 의 @a 그대로 사용
    expect(stdout).toContain('CLI_ALIAS_B'); // CLI 의 @b 가 config 를 override
    rmSync(dir, { recursive: true, force: true });
  });

  test('config 의 define 객체 + CLI define 머지 — 키 단위 override', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-define-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `console.log(__VER__);
       console.log(__BUILD__);`,
    );
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({
        define: { __VER__: '"v_from_config"', __BUILD__: '"build_from_config"' },
      }),
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', '--define:__BUILD__="build_from_cli"', join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('v_from_config'); // config 만 정의 → 그대로
    expect(stdout).toContain('build_from_cli'); // CLI override
    rmSync(dir, { recursive: true, force: true });
  });

  test('config 의 external 배열 — CLI external 빈 상태면 config 사용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-external-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `import * as path from "node:path";
       import * as fs from "node:fs";
       console.log(path, fs);`,
    );
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ external: ['node:path', 'node:fs'] }),
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    // external 이면 require/import 가 그대로 보존
    expect(stdout).toMatch(/node:path/);
    expect(stdout).toMatch(/node:fs/);
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
    // es5 타겟이면 array destructuring 이 down-leveling 되어 .slice 호출이 나와야 함
    expect(stdout).toContain('.slice(');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig + config + CLI 3-way 우선순위: CLI > config > tsconfig', () => {
    // tsconfig 가 jsx=preserve, config 가 jsx=automatic, CLI 가 jsx=transform.
    // 결과는 transform (CLI 우선).
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
    // jsx=transform → React.createElement 호출 (legacy classic).
    expect(stdout).toContain('React.createElement');
    expect(stdout).not.toContain('jsx-runtime'); // automatic 미사용
    expect(stdout).not.toContain('<div>'); // preserve 미사용
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── 함수형 config + --config <path> + --mode (#2103 / Phase 2-1) ───
