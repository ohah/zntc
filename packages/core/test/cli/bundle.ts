import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  mkdirSync,
  tmpdir,
  join,
  resolve,
  runCli,
} from './helpers';

describe('CLI: bundle', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-cli-bundle-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'import { hello } from "./util";\nconsole.log(hello("world"));',
    );
    writeFileSync(
      join(dir, 'util.ts'),
      'export function hello(name: string): string { return `Hello, ${name}!`; }',
    );
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('번들 → stdout', () => {
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('hello');
    expect(stdout).toContain('Hello');
  });

  test('번들 → -o 파일 출력', () => {
    const outFile = join(dir, 'bundle.js');
    const { exitCode } = runCli(['--bundle', join(dir, 'entry.ts'), '-o', outFile]);
    expect(exitCode).toBe(0);
    const content = readFileSync(outFile, 'utf8');
    expect(content).toContain('hello');
  });

  test('번들 → --outdir 출력', () => {
    const outDir = join(dir, 'dist');
    const { exitCode } = runCli(['--bundle', join(dir, 'entry.ts'), '--outdir', outDir]);
    expect(exitCode).toBe(0);
    expect(existsSync(outDir)).toBe(true);
  });

  test('번들 --allow-overwrite 미지정 시 입력=출력 차단', () => {
    const overwriteDir = mkdtempSync(join(tmpdir(), 'zntc-cli-bundle-overwrite-'));
    try {
      const file = join(overwriteDir, 'entry.js');
      writeFileSync(file, 'export const value = 1;\n');
      const { exitCode, stderr } = runCli(['--bundle', file, '-o', file]);
      expect(exitCode).toBe(1);
      expect(stderr).toContain('would overwrite input file');
    } finally {
      rmSync(overwriteDir, { recursive: true, force: true });
    }
  });

  test('번들 --allow-overwrite 지정 시 입력=출력 허용', () => {
    const overwriteDir = mkdtempSync(join(tmpdir(), 'zntc-cli-bundle-overwrite-'));
    try {
      const file = join(overwriteDir, 'entry.js');
      writeFileSync(file, 'export const value = 1;\n');
      const { exitCode, stderr } = runCli(['--bundle', file, '-o', file, '--allow-overwrite']);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('would overwrite');
      expect(readFileSync(file, 'utf8')).toContain('value');
    } finally {
      rmSync(overwriteDir, { recursive: true, force: true });
    }
  });

  test('번들 + --minify', () => {
    const normal = runCli(['--bundle', join(dir, 'entry.ts')]);
    const minified = runCli(['--bundle', join(dir, 'entry.ts'), '--minify']);
    expect(minified.exitCode).toBe(0);
    expect(minified.stdout.length).toBeLessThan(normal.stdout.length);
  });

  test('번들 + --runtime-polyfills=auto + --runtime-target', () => {
    const polyfillDir = mkdtempSync(join(tmpdir(), 'zntc-cli-runtime-polyfills-'));
    try {
      writeFileSync(
        join(polyfillDir, 'entry.ts'),
        `globalThis.__VALUE__ = "a".replaceAll("a", "b");`,
      );

      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(polyfillDir, 'entry.ts'),
        '--runtime-polyfills=auto',
        '--runtime-target=ios_saf 12',
      ]);

      expect(exitCode).toBe(0);
      expect(stderr).toBe('');
      expect(stdout).toContain('es.string.replace-all');
    } finally {
      rmSync(polyfillDir, { recursive: true, force: true });
    }
  });

  test('번들 + --runtime-polyfills=usage 는 graph usage alias로 동작', () => {
    const polyfillDir = mkdtempSync(join(tmpdir(), 'zntc-cli-runtime-usage-'));
    try {
      writeFileSync(
        join(polyfillDir, 'entry.ts'),
        `globalThis.__VALUE__ = new Map([["x", 1]]).get("x");`,
      );

      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(polyfillDir, 'entry.ts'),
        '--runtime-polyfills=usage',
        '--runtime-target=safari 5',
      ]);

      expect(exitCode).toBe(0);
      expect(stderr).toBe('');
      expect(stdout).toContain('es.map');
    } finally {
      rmSync(polyfillDir, { recursive: true, force: true });
    }
  });

  test('번들 + runtime-polyfills debug/profile 관측성 출력', () => {
    const polyfillDir = mkdtempSync(join(tmpdir(), 'zntc-cli-runtime-observe-'));
    try {
      writeFileSync(
        join(polyfillDir, 'entry.ts'),
        `globalThis.__VALUE__ = "a".replaceAll("a", "b");`,
      );

      const { stdout, stderr, exitCode } = runCli(
        [
          '--bundle',
          join(polyfillDir, 'entry.ts'),
          '--runtime-polyfills=auto',
          '--runtime-target=ios_saf 12',
          '--profile=graph',
          '--profile-level=detailed',
          '--profile-format=json',
        ],
        { env: { ...process.env, ZNTC_DEBUG: 'runtime_polyfills' } },
      );

      expect(exitCode).toBe(0);
      expect(stdout).toContain('es.string.replace-all');
      expect(stderr).toContain('[runtime_polyfills]');
      expect(stderr).toContain('mode=usage');
      expect(stderr).toContain('feature=string_replace_all');
      expect(stderr).toContain('corejs_module=es.string.replace-all');
      expect(stderr).toContain('"graph.runtime.polyfills.collect"');
      expect(stderr).toContain('"graph.runtime.polyfills.inject"');
    } finally {
      rmSync(polyfillDir, { recursive: true, force: true });
    }
  });

  test('번들 + --runtime-polyfills=off 는 collector/profile/debug 경로를 실행하지 않음', () => {
    const polyfillDir = mkdtempSync(join(tmpdir(), 'zntc-cli-runtime-off-observe-'));
    try {
      writeFileSync(
        join(polyfillDir, 'entry.ts'),
        `globalThis.__VALUE__ = "a".replaceAll("a", "b");`,
      );

      const { stdout, stderr, exitCode } = runCli(
        [
          '--bundle',
          join(polyfillDir, 'entry.ts'),
          '--runtime-polyfills=off',
          '--runtime-target=ios_saf 12',
          '--profile=graph',
          '--profile-level=detailed',
          '--profile-format=json',
        ],
        { env: { ...process.env, ZNTC_DEBUG: 'runtime_polyfills' } },
      );

      expect(exitCode).toBe(0);
      expect(stdout).not.toContain('es.string.replace-all');
      expect(stderr).not.toContain('[runtime_polyfills]');
      expect(stderr).not.toContain('graph.runtime.polyfills');
    } finally {
      rmSync(polyfillDir, { recursive: true, force: true });
    }
  });

  test('번들 + --runtime-target device name은 actionable error', () => {
    const polyfillDir = mkdtempSync(join(tmpdir(), 'zntc-cli-runtime-device-'));
    try {
      writeFileSync(
        join(polyfillDir, 'entry.ts'),
        `globalThis.__VALUE__ = "a".replaceAll("a", "b");`,
      );

      const { stderr, exitCode } = runCli([
        '--bundle',
        join(polyfillDir, 'entry.ts'),
        '--runtime-polyfills=auto',
        '--runtime-target',
        'iPhone 8',
      ]);

      expect(exitCode).not.toBe(0);
      expect(stderr).toContain('Physical device names are not supported');
      expect(stderr).toContain('ios_saf 12');
    } finally {
      rmSync(polyfillDir, { recursive: true, force: true });
    }
  });

  test('번들 + --runtime-target compact shorthand는 거부', () => {
    const polyfillDir = mkdtempSync(join(tmpdir(), 'zntc-cli-runtime-shorthand-'));
    try {
      writeFileSync(
        join(polyfillDir, 'entry.ts'),
        `globalThis.__VALUE__ = "a".replaceAll("a", "b");`,
      );

      const { stderr, exitCode } = runCli([
        '--bundle',
        join(polyfillDir, 'entry.ts'),
        '--runtime-polyfills=auto',
        '--runtime-target=ios12',
      ]);

      expect(exitCode).not.toBe(0);
      expect(stderr).toContain('Compact runtime target shorthands');
    } finally {
      rmSync(polyfillDir, { recursive: true, force: true });
    }
  });

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

  test('번들 + --sourcemap + -o', () => {
    const outFile = join(dir, 'bundle-sm.js');
    const { exitCode } = runCli(['--bundle', join(dir, 'entry.ts'), '--sourcemap', '-o', outFile]);
    expect(exitCode).toBe(0);
    expect(existsSync(outFile + '.map')).toBe(true);
  });

  test('번들 + --metafile', () => {
    const outDir = join(dir, 'meta-out');
    const { exitCode } = runCli([
      '--bundle',
      join(dir, 'entry.ts'),
      '--metafile',
      '--outdir',
      outDir,
    ]);
    expect(exitCode).toBe(0);
    // metafile은 meta.json으로 저장
    expect(existsSync(resolve('meta.json'))).toBe(true);
    rmSync(resolve('meta.json'), { force: true });
  });

  test('번들 + --format=cjs', () => {
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts'), '--format=cjs']);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('use strict');
  });

  test('번들 + --intro/--outro wrapper 내부 텍스트 삽입', () => {
    const { stdout, stderr, exitCode } = runCli([
      '--bundle',
      join(dir, 'entry.ts'),
      "--intro=console.log('intro');",
      "--outro=console.log('outro');",
    ]);
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('unknown option');
    expect(stdout).toContain("console.log('intro');");
    expect(stdout).toContain("console.log('outro');");
    expect(stdout.indexOf("console.log('intro');")).toBeLessThan(stdout.indexOf('Hello'));
    expect(stdout.indexOf('Hello')).toBeLessThan(stdout.indexOf("console.log('outro');"));
  });

  test('번들 + --node-paths=<csv> 추가 lookup directory에서 bare specifier resolve', () => {
    const npDir = mkdtempSync(join(tmpdir(), 'zntc-cli-node-paths-'));
    try {
      const vendor = join(npDir, 'vendor');
      mkdirSync(join(vendor, 'pkg'), { recursive: true });
      writeFileSync(join(vendor, 'pkg', 'package.json'), JSON.stringify({ main: 'index.js' }));
      writeFileSync(join(vendor, 'pkg', 'index.js'), "export const value = 'NODE_PATH_VALUE';");
      writeFileSync(join(npDir, 'entry.ts'), "import { value } from 'pkg'; console.log(value);");
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(npDir, 'entry.ts'),
        `--node-paths=${vendor}`,
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('NODE_PATH_VALUE');
    } finally {
      rmSync(npDir, { recursive: true, force: true });
    }
  });

  test('번들 + --global:SPEC=NAME maps IIFE external globals', () => {
    const globalDir = mkdtempSync(join(tmpdir(), 'zntc-cli-globals-'));
    try {
      writeFileSync(
        join(globalDir, 'entry.ts'),
        "import { useState } from 'react'; console.log(useState);",
      );
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(globalDir, 'entry.ts'),
        '--format=iife',
        '--global-name=Lib',
        '--external',
        'react',
        '--global:react=React',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('})(React);');
      expect(stdout).toContain('React.useState');
    } finally {
      rmSync(globalDir, { recursive: true, force: true });
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

  test('번들 + --conditions=<csv> custom exports condition 적용', () => {
    const condDir = mkdtempSync(join(tmpdir(), 'zntc-cli-conditions-'));
    try {
      mkdirSync(join(condDir, 'node_modules', 'pkg'), { recursive: true });
      writeFileSync(
        join(condDir, 'node_modules', 'pkg', 'package.json'),
        JSON.stringify({
          name: 'pkg',
          exports: {
            '.': {
              custom: './custom.js',
              default: './default.js',
            },
          },
        }),
      );
      writeFileSync(
        join(condDir, 'node_modules', 'pkg', 'custom.js'),
        "export const value = 'custom';",
      );
      writeFileSync(
        join(condDir, 'node_modules', 'pkg', 'default.js'),
        "export const value = 'default';",
      );
      writeFileSync(join(condDir, 'entry.ts'), "import { value } from 'pkg'; console.log(value);");
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(condDir, 'entry.ts'),
        '--conditions=custom',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('custom');
      expect(stdout).not.toContain('default');
    } finally {
      rmSync(condDir, { recursive: true, force: true });
    }
  });

  test('번들 + --profile emits profile report', () => {
    const { stderr, exitCode } = runCli([
      '--bundle',
      join(dir, 'entry.ts'),
      '--profile=all',
      '--profile-format=table',
      '-o',
      join(dir, 'profile-bundle.js'),
    ]);
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('unknown option');
    expect(stderr).toContain('=== ZNTC Profile ===');
  });

  test('번들 + --format=iife', () => {
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts'), '--format=iife']);
    expect(exitCode).toBe(0);
    expect(stdout.includes('(function') || stdout.includes('(()')).toBe(true);
  });

  test('번들 + --external', () => {
    const extDir = mkdtempSync(join(tmpdir(), 'zntc-cli-ext-'));
    writeFileSync(join(extDir, 'app.ts'), 'import React from "react";\nconsole.log(React);');
    const { stdout, exitCode } = runCli([
      '--bundle',
      join(extDir, 'app.ts'),
      '--external',
      'react',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('react');
    rmSync(extDir, { recursive: true, force: true });
  });

  test('번들 + --packages=external 은 bare package만 external 처리', () => {
    const extDir = mkdtempSync(join(tmpdir(), 'zntc-cli-packages-ext-'));
    try {
      writeFileSync(
        join(extDir, 'app.ts'),
        'import React from "react";\nimport { local } from "./local";\nconsole.log(React, local);',
      );
      writeFileSync(join(extDir, 'local.ts'), "export const local = 'LOCAL_INCLUDED';");
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(extDir, 'app.ts'),
        '--packages=external',
        '--format=esm',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('"react"');
      expect(stdout).toContain('LOCAL_INCLUDED');
      expect(stdout).not.toContain('from "./local"');
    } finally {
      rmSync(extDir, { recursive: true, force: true });
    }
  });

  test('번들 + --banner:js + --footer:js (esbuild 호환 alias)', () => {
    const { stdout, exitCode } = runCli([
      '--bundle',
      join(dir, 'entry.ts'),
      '--banner:js=/* banner */',
      '--footer:js=/* footer */',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* banner */');
    expect(stdout).toContain('/* footer */');
  });

  test('번들 + --banner + --footer (정식 형태 — BuildOptions.banner 와 1:1)', () => {
    const { stdout, exitCode } = runCli([
      '--bundle',
      join(dir, 'entry.ts'),
      '--banner=/* TOP */',
      '--footer=/* BOTTOM */',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* TOP */');
    expect(stdout).toContain('/* BOTTOM */');
  });

  test('번들 + --target=es5 (ES 다운레벨)', () => {
    // arrow function `() =>` 가 target=es5 면 `function()` 으로 다운레벨.
    const arrowDir = mkdtempSync(join(tmpdir(), 'zntc-cli-target-'));
    writeFileSync(join(arrowDir, 'entry.ts'), 'const fn = () => 42; console.log(fn());');
    const { stdout, exitCode } = runCli(['--bundle', join(arrowDir, 'entry.ts'), '--target=es5']);
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('=>'); // arrow 가 사라져야 함
    rmSync(arrowDir, { recursive: true, force: true });
  });

  test('번들 + --browserslist (target 보다 우선, modern 쿼리는 arrow 보존)', () => {
    const blDir = mkdtempSync(join(tmpdir(), 'zntc-cli-browserslist-'));
    writeFileSync(join(blDir, 'entry.ts'), 'const fn = () => 42; console.log(fn());');
    // `--target=es5` 와 함께 줘도 browserslist 가 우선이라 arrow 가 살아 있어야 — 우선순위 검증.
    const { stdout, exitCode } = runCli([
      '--bundle',
      join(blDir, 'entry.ts'),
      '--target=es5',
      '--browserslist=last 1 chrome version',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('=>');
    rmSync(blDir, { recursive: true, force: true });
  });

  test('--emit-decorator-metadata + --experimental-decorators', () => {
    const decDir = mkdtempSync(join(tmpdir(), 'zntc-cli-decorator-'));
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
    rmSync(decDir, { recursive: true, force: true });
  });

  test('--jsx-in-js — .js 파일에서도 JSX 파싱 (classic 모드 — runtime resolve 회피)', () => {
    const jsxDir = mkdtempSync(join(tmpdir(), 'zntc-cli-jsx-in-js-'));
    writeFileSync(
      join(jsxDir, 'entry.js'),
      'function React_createElement() {} const el = <div>OK</div>; console.log(el);',
    );
    const { stdout, exitCode } = runCli([
      '--bundle',
      join(jsxDir, 'entry.js'),
      '--jsx-in-js',
      '--jsx=classic',
      '--jsx-factory=React_createElement',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('React_createElement');
    expect(stdout).not.toContain('<div>'); // JSX 가 transpile 됐어야
    rmSync(jsxDir, { recursive: true, force: true });
  });

  test('--verbatim-module-syntax — flag 가 NAPI 까지 reach (실 동작 미구현은 별도)', () => {
    // 이 PR 은 CLI flag 노출만 — 실제 type-only import 보존은 NAPI 측 미구현 (별도 이슈).
    // 회귀 방지: flag 로 인해 transpile 이 깨지지 않고, 일반 import 는 정상 처리.
    const vmsDir = mkdtempSync(join(tmpdir(), 'zntc-cli-vms-'));
    writeFileSync(
      join(vmsDir, 'entry.ts'),
      "import type { X } from './t.ts';\nimport { y } from './t.ts';\nconsole.log(y);",
    );
    writeFileSync(join(vmsDir, 't.ts'), 'export type X = number;\nexport const y = 1;');
    const { stdout, exitCode } = runCli([join(vmsDir, 'entry.ts'), '--verbatim-module-syntax']);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('import'); // 일반 import 는 살아있음 — flag 가 출력 깨뜨리지 않음
    rmSync(vmsDir, { recursive: true, force: true });
  });

  test('--banner 가 = 안의 = 도 보존', () => {
    // `--banner=key=value` 같이 value 안에 = 가 있어도 split 으로 truncation 안 됨.
    const { stdout, exitCode } = runCli([
      '--bundle',
      join(dir, 'entry.ts'),
      '--banner=/* key=value */',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* key=value */');
  });

  test('번들 + --clean (outdir 정리 후 빌드)', () => {
    const outDir = join(dir, 'clean-out');
    mkdirSync(outDir, { recursive: true });
    writeFileSync(join(outDir, 'stale.js'), 'stale');

    const { exitCode } = runCli(['--bundle', join(dir, 'entry.ts'), '--outdir', outDir, '--clean']);
    expect(exitCode).toBe(0);
    // stale.js가 삭제됨
    expect(existsSync(join(outDir, 'stale.js'))).toBe(false);
  });

  test('존재하지 않는 entry → 에러', () => {
    const { exitCode } = runCli(['--bundle', '/nonexistent/entry.ts']);
    expect(exitCode).toBe(1);
  });
});

// ─── import.meta.glob ───
