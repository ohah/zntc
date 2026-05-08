import {
  afterAll,
  beforeAll,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

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
});
