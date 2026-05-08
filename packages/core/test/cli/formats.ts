import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  PROJECT_ROOT,
  runCli,
  runNodeEval,
} from './helpers';

describe('CLI: UMD/AMD format', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-cli-umd-'));
    writeFileSync(
      join(dir, 'app.ts'),
      'import { useState } from "react";\nexport function App() { return useState(0); }',
    );
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('UMD: external dependency array + factory params', () => {
    const { stdout, exitCode } = runCli([
      '--bundle',
      join(dir, 'app.ts'),
      '--format=umd',
      '--external',
      'react',
      '--global-name=MyApp',
    ]);
    expect(exitCode).toBe(0);
    // dependency array에 "react" 포함
    expect(stdout).toContain('define(["react"]');
    // factory 매개변수
    expect(stdout).toContain('function(React)');
    // CJS require 경로
    expect(stdout).toContain('require("react")');
    // IIFE 글로벌
    expect(stdout).toContain('root.React');
    // body에 named import → factory param 프로퍼티 접근
    expect(stdout).toContain('React.useState');
    // body에 bare require("react") 없음
    expect(stdout).not.toContain('var React = require("react")');
  });

  test('AMD: external dependency array + factory params', () => {
    const { stdout, exitCode } = runCli([
      '--bundle',
      join(dir, 'app.ts'),
      '--format=amd',
      '--external',
      'react',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('define(["react"]');
    expect(stdout).toContain('function(React)');
    expect(stdout).toContain('React.useState');
  });

  test('UMD: Node.js에서 실행 가능', () => {
    // react mock + UMD 번들을 Node.js에서 실행
    const mockDir = mkdtempSync(join(tmpdir(), 'zntc-umd-e2e-'));
    writeFileSync(
      join(mockDir, 'app.ts'),
      'import { greet } from "mylib";\nexport const msg = greet("world");',
    );
    mkdirSync(join(mockDir, 'node_modules', 'mylib'), { recursive: true });
    writeFileSync(
      join(mockDir, 'node_modules', 'mylib', 'index.js'),
      'exports.greet = function(n) { return "Hello " + n; };',
    );

    const outFile = join(mockDir, 'bundle.js');
    const { exitCode } = runCli([
      '--bundle',
      join(mockDir, 'app.ts'),
      '--format=umd',
      '--external',
      'mylib',
      '-o',
      outFile,
    ]);
    expect(exitCode).toBe(0);

    // Node.js에서 UMD 번들 require → CJS 경로로 실행
    const run = runNodeEval(`const m = require(${JSON.stringify(outFile)}); console.log(m.msg);`, {
      cwd: mockDir,
    });
    expect(run.stdout.trim()).toBe('Hello world');

    rmSync(mockDir, { recursive: true, force: true });
  });

  test('UMD: 실제 React로 CJS 실행 E2E', () => {
    const umdDir = mkdtempSync(join(tmpdir(), 'zntc-umd-react-'));
    writeFileSync(
      join(umdDir, 'pure.tsx'),
      [
        'import React, { createElement } from "react";',
        'export function Greeting(props: { name: string }) {',
        '  return createElement("h1", null, "Hello " + props.name);',
        '}',
        'export const version = React.version;',
      ].join('\n'),
    );

    const outFile = join(umdDir, 'bundle.js');
    const { exitCode } = runCli([
      '--bundle',
      join(umdDir, 'pure.tsx'),
      '--format=umd',
      '--external',
      'react',
      '--global-name=MyLib',
      '-o',
      outFile,
    ]);
    expect(exitCode).toBe(0);

    // Node.js에서 UMD 번들을 require → 실제 React 모듈이 factory로 주입됨
    const projectRoot = PROJECT_ROOT;
    const run = runNodeEval(
      `const m = require(${JSON.stringify(outFile)}); console.log(m.version); const el = m.Greeting({ name: "ZNTC" }); console.log(el.type + ":" + el.props.children);`,
      {
        cwd: projectRoot,
        env: { ...process.env, NODE_PATH: join(projectRoot, 'node_modules') },
      },
    );
    const lines = run.stdout.trim().split('\n');
    // React.version이 존재 (실제 react 패키지에서 읽힌 값)
    expect(lines[0]).toMatch(/^\d+\.\d+\.\d+$/);
    // createElement 결과: h1:Hello ZNTC
    expect(lines[1]).toBe('h1:Hello ZNTC');

    rmSync(umdDir, { recursive: true, force: true });
  });

  test('AMD: 실제 React로 출력 구조 검증', () => {
    const amdDir = mkdtempSync(join(tmpdir(), 'zntc-amd-react-'));
    writeFileSync(
      join(amdDir, 'lib.tsx'),
      'import React from "react";\nexport const ver = React.version;\nexport const el = React.createElement("span", null, "hi");',
    );

    const { stdout, exitCode } = runCli([
      '--bundle',
      join(amdDir, 'lib.tsx'),
      '--format=amd',
      '--external',
      'react',
    ]);
    expect(exitCode).toBe(0);
    // AMD wrapper 구조
    expect(stdout).toContain('define(["react"]');
    expect(stdout).toContain('function(React)');
    // body에서 React 직접 참조 (require 아님)
    expect(stdout).toContain('React.version');
    expect(stdout).toContain('React.createElement');
    // bare require("react") 없음
    expect(stdout).not.toContain('require("react")');

    rmSync(amdDir, { recursive: true, force: true });
  });
});

// ─── Bundle + Plugin ───
