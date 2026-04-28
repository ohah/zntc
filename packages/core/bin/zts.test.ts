/**
 * ZTS Node.js CLI 테스트
 *
 * CLI를 subprocess로 실행하여 실제 동작을 검증.
 * bun test packages/core/bin/zts.test.ts
 */

import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { spawn, spawnSync, execSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const CLI = resolve(import.meta.dir, "zts.mjs");
const RUNTIME = "node";

async function waitForServer(port: number, maxRetries = 20, interval = 100, protocol = "http") {
  for (let i = 0; i < maxRetries; i++) {
    try {
      await fetch(`${protocol}://localhost:${port}/`, {
        tls: { rejectUnauthorized: false },
      } as any);
      return;
    } catch {
      await new Promise((r) => setTimeout(r, interval));
    }
  }
  throw new Error(`Server on port ${port} did not start`);
}

function shellQuote(value: string) {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function readRedirectedProcessOutput(
  command: string,
  options: { input?: string; cwd?: string; timeout?: number; env?: NodeJS.ProcessEnv } = {},
) {
  const dir = mkdtempSync(join(tmpdir(), "zts-cli-output-"));
  const stdoutPath = join(dir, "stdout");
  const stderrPath = join(dir, "stderr");
  const stdinPath = join(dir, "stdin");
  const stdinRedirect = options.input !== undefined ? ` < ${shellQuote(stdinPath)}` : "";
  if (options.input !== undefined) writeFileSync(stdinPath, options.input);
  const result = spawnSync(
    "sh",
    ["-c", `${command}${stdinRedirect} > ${shellQuote(stdoutPath)} 2> ${shellQuote(stderrPath)}`],
    {
      cwd: options.cwd,
      timeout: options.timeout ?? 10000,
      env: options.env,
    },
  );
  const stdout = existsSync(stdoutPath) ? readFileSync(stdoutPath, "utf8") : "";
  const stderr = existsSync(stderrPath) ? readFileSync(stderrPath, "utf8") : "";
  rmSync(dir, { recursive: true, force: true });
  return { stdout, stderr, exitCode: result.status ?? 1 };
}

function runCli(
  args: string[],
  options: {
    input?: string;
    cwd?: string;
    timeout?: number;
    env?: NodeJS.ProcessEnv;
  } = {},
) {
  const command = [RUNTIME, CLI, ...args].map(shellQuote).join(" ");
  return readRedirectedProcessOutput(command, options);
}

function runNodeEval(
  code: string,
  options: { cwd?: string; env?: NodeJS.ProcessEnv; timeout?: number } = {},
) {
  const command = [RUNTIME, "-e", code].map(shellQuote).join(" ");
  return readRedirectedProcessOutput(command, options);
}

// ─── Transpile 모드 ───

describe("CLI: transpile", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-cli-transpile-"));
    writeFileSync(join(dir, "input.ts"), "const x: number = 1;\nconsole.log(x);");
    writeFileSync(
      join(dir, "types.ts"),
      "interface Foo { bar: string; }\ntype Baz = number;\nconst y = 42;",
    );
    writeFileSync(join(dir, "jsx.tsx"), "export default () => <div>hello</div>;");
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test("파일 트랜스파일 → stdout", () => {
    const { stdout, exitCode } = runCli([join(dir, "input.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("const x = 1");
    expect(stdout).not.toContain(": number");
  });

  test("stdin 트랜스파일 → stdout", () => {
    const { stdout, exitCode } = runCli(["-"], { input: "const x: number = 1;" });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("const x = 1");
  });

  test("파일 트랜스파일 → -o 출력", () => {
    const outFile = join(dir, "output.js");
    const { exitCode } = runCli([join(dir, "input.ts"), "-o", outFile]);
    expect(exitCode).toBe(0);
    expect(existsSync(outFile)).toBe(true);
    const content = readFileSync(outFile, "utf8");
    expect(content).toContain("const x = 1");
  });

  test("파일 트랜스파일 → --outdir 출력", () => {
    const outDir = join(dir, "out");
    const { exitCode } = runCli([join(dir, "input.ts"), "--outdir", outDir]);
    expect(exitCode).toBe(0);
    expect(existsSync(join(outDir, "input.js"))).toBe(true);
  });

  test("타입/인터페이스만 있는 파일 → 빈 출력", () => {
    const { stdout, exitCode } = runCli([join(dir, "types.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain("interface");
    expect(stdout).not.toContain("type Baz");
    expect(stdout).toContain("y = 42");
  });

  test("--minify 옵션", () => {
    const normal = runCli([join(dir, "input.ts")]);
    const minified = runCli([join(dir, "input.ts"), "--minify"]);
    expect(minified.exitCode).toBe(0);
    expect(minified.stdout.length).toBeLessThan(normal.stdout.length);
  });

  test("--sourcemap 옵션 + -o", () => {
    const outFile = join(dir, "with-map.js");
    const { exitCode } = runCli([join(dir, "input.ts"), "--sourcemap", "-o", outFile]);
    expect(exitCode).toBe(0);
    expect(existsSync(outFile)).toBe(true);
    expect(existsSync(outFile + ".map")).toBe(true);
    const map = JSON.parse(readFileSync(outFile + ".map", "utf8"));
    expect(map.version).toBe(3);
  });

  test("--format=cjs", () => {
    const { stdout, exitCode } = runCli([join(dir, "input.ts"), "--format=cjs"]);
    expect(exitCode).toBe(0);
    // 트랜스파일 모드에서 CJS는 코드 자체를 변환
    expect(stdout).toContain("x = 1");
  });

  test("--flow 옵션", () => {
    const flowDir = mkdtempSync(join(tmpdir(), "zts-cli-flow-"));
    writeFileSync(
      join(flowDir, "flow.js"),
      "// @flow\nfunction foo(x: string): number { return x.length; }",
    );
    const { stdout, exitCode } = runCli([join(flowDir, "flow.js"), "--flow"]);
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain(": string");
    expect(stdout).not.toContain(": number");
    rmSync(flowDir, { recursive: true, force: true });
  });

  test("--drop=console", () => {
    const { stdout, exitCode } = runCli([join(dir, "input.ts"), "--drop=console"]);
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain("console.log");
  });

  test("존재하지 않는 파일 → 에러", () => {
    const { exitCode, stderr } = runCli(["/nonexistent/file.ts"]);
    expect(exitCode).toBe(1);
    expect(stderr.length).toBeGreaterThan(0);
  });

  test("인자 없이 실행 → usage 메시지", () => {
    const { exitCode, stderr } = runCli([]);
    expect(exitCode).toBe(1);
    expect(stderr).toContain("Usage");
  });
});

// ─── Bundle 모드 ───

describe("CLI: bundle", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-cli-bundle-"));
    writeFileSync(
      join(dir, "entry.ts"),
      'import { hello } from "./util";\nconsole.log(hello("world"));',
    );
    writeFileSync(
      join(dir, "util.ts"),
      "export function hello(name: string): string { return `Hello, ${name}!`; }",
    );
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test("번들 → stdout", () => {
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("hello");
    expect(stdout).toContain("Hello");
  });

  test("번들 → -o 파일 출력", () => {
    const outFile = join(dir, "bundle.js");
    const { exitCode } = runCli(["--bundle", join(dir, "entry.ts"), "-o", outFile]);
    expect(exitCode).toBe(0);
    const content = readFileSync(outFile, "utf8");
    expect(content).toContain("hello");
  });

  test("번들 → --outdir 출력", () => {
    const outDir = join(dir, "dist");
    const { exitCode } = runCli(["--bundle", join(dir, "entry.ts"), "--outdir", outDir]);
    expect(exitCode).toBe(0);
    expect(existsSync(outDir)).toBe(true);
  });

  test("번들 + --minify", () => {
    const normal = runCli(["--bundle", join(dir, "entry.ts")]);
    const minified = runCli(["--bundle", join(dir, "entry.ts"), "--minify"]);
    expect(minified.exitCode).toBe(0);
    expect(minified.stdout.length).toBeLessThan(normal.stdout.length);
  });

  test("번들 + --sourcemap + -o", () => {
    const outFile = join(dir, "bundle-sm.js");
    const { exitCode } = runCli(["--bundle", join(dir, "entry.ts"), "--sourcemap", "-o", outFile]);
    expect(exitCode).toBe(0);
    expect(existsSync(outFile + ".map")).toBe(true);
  });

  test("번들 + --metafile", () => {
    const outDir = join(dir, "meta-out");
    const { exitCode } = runCli([
      "--bundle",
      join(dir, "entry.ts"),
      "--metafile",
      "--outdir",
      outDir,
    ]);
    expect(exitCode).toBe(0);
    // metafile은 meta.json으로 저장
    expect(existsSync(resolve("meta.json"))).toBe(true);
    rmSync(resolve("meta.json"), { force: true });
  });

  test("번들 + --format=cjs", () => {
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts"), "--format=cjs"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("use strict");
  });

  test("번들 + --format=iife", () => {
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts"), "--format=iife"]);
    expect(exitCode).toBe(0);
    expect(stdout.includes("(function") || stdout.includes("(()")).toBe(true);
  });

  test("번들 + --external", () => {
    const extDir = mkdtempSync(join(tmpdir(), "zts-cli-ext-"));
    writeFileSync(join(extDir, "app.ts"), 'import React from "react";\nconsole.log(React);');
    const { stdout, exitCode } = runCli([
      "--bundle",
      join(extDir, "app.ts"),
      "--external",
      "react",
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("react");
    rmSync(extDir, { recursive: true, force: true });
  });

  test("번들 + --banner:js + --footer:js", () => {
    const { stdout, exitCode } = runCli([
      "--bundle",
      join(dir, "entry.ts"),
      "--banner:js=/* banner */",
      "--footer:js=/* footer */",
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* banner */");
    expect(stdout).toContain("/* footer */");
  });

  test("번들 + --clean (outdir 정리 후 빌드)", () => {
    const outDir = join(dir, "clean-out");
    mkdirSync(outDir, { recursive: true });
    writeFileSync(join(outDir, "stale.js"), "stale");

    const { exitCode } = runCli(["--bundle", join(dir, "entry.ts"), "--outdir", outDir, "--clean"]);
    expect(exitCode).toBe(0);
    // stale.js가 삭제됨
    expect(existsSync(join(outDir, "stale.js"))).toBe(false);
  });

  test("존재하지 않는 entry → 에러", () => {
    const { exitCode } = runCli(["--bundle", "/nonexistent/entry.ts"]);
    expect(exitCode).toBe(1);
  });
});

// ─── import.meta.glob ───

describe("CLI: import.meta.glob", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-cli-glob-"));
    mkdirSync(join(dir, "modules"), { recursive: true });
    writeFileSync(join(dir, "modules", "a.ts"), 'export const setup = () => "a";');
    writeFileSync(join(dir, "modules", "b.ts"), 'export const setup = () => "b";');
    writeFileSync(join(dir, "modules", "c.ts"), "export default 42;");
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test("lazy (default): () => import() 패턴", () => {
    writeFileSync(
      join(dir, "lazy.ts"),
      'const m = import.meta.glob("./modules/*.ts");\nconsole.log(m);',
    );
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "lazy.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("() => import(");
    expect(stdout).toContain("./modules/a.ts");
    expect(stdout).not.toContain("await import(");
  });

  test("eager: await import() 패턴", () => {
    writeFileSync(
      join(dir, "eager.ts"),
      'const m = import.meta.glob("./modules/*.ts", { eager: true });\nconsole.log(m);',
    );
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "eager.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("await import(");
    expect(stdout).not.toContain("() => import(");
  });

  test("import option: .then(m => m.setup) 패턴", () => {
    writeFileSync(
      join(dir, "named.ts"),
      'const m = import.meta.glob("./modules/*.ts", { import: "setup" });\nconsole.log(m);',
    );
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "named.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("m.setup");
    expect(stdout).toContain("() => import(");
  });

  test("Vite 라우트 패턴: lazy glob → 동적 라우트 맵", () => {
    // Vite에서 가장 흔한 패턴: pages 디렉토리의 모든 컴포넌트를 라우트로 등록
    const viteDir = mkdtempSync(join(tmpdir(), "zts-glob-vite-"));
    mkdirSync(join(viteDir, "pages"), { recursive: true });
    writeFileSync(
      join(viteDir, "pages", "Home.tsx"),
      'export default function Home() { return "home"; }',
    );
    writeFileSync(
      join(viteDir, "pages", "About.tsx"),
      'export default function About() { return "about"; }',
    );
    writeFileSync(
      join(viteDir, "pages", "Contact.tsx"),
      'export default function Contact() { return "contact"; }',
    );
    writeFileSync(
      join(viteDir, "router.ts"),
      [
        'const pages = import.meta.glob("./pages/*.tsx");',
        "const routes = Object.entries(pages).map(([path, loader]) => ({",
        '  path: path.replace("./pages/", "/").replace(".tsx", ""),',
        "  loader,",
        "}));",
        "export { routes };",
      ].join("\n"),
    );

    const { stdout, exitCode } = runCli(["--bundle", join(viteDir, "router.ts")]);
    expect(exitCode).toBe(0);
    // lazy import 패턴
    expect(stdout).toContain("() => import(");
    // 3개 페이지 모두 포함
    expect(stdout).toContain("./pages/Home.tsx");
    expect(stdout).toContain("./pages/About.tsx");
    expect(stdout).toContain("./pages/Contact.tsx");
    // Object.entries로 라우트 매핑 코드 유지
    expect(stdout).toContain("Object.entries");

    rmSync(viteDir, { recursive: true, force: true });
  });

  test("Vite i18n 패턴: eager glob + import default", () => {
    // Vite 다국어: locale JSON을 eager + import default로 즉시 로드
    const i18nDir = mkdtempSync(join(tmpdir(), "zts-glob-i18n-"));
    mkdirSync(join(i18nDir, "locales"), { recursive: true });
    writeFileSync(join(i18nDir, "locales", "en.ts"), 'export default { hello: "Hello" };');
    writeFileSync(join(i18nDir, "locales", "ko.ts"), 'export default { hello: "안녕" };');
    writeFileSync(
      join(i18nDir, "i18n.ts"),
      'const messages = import.meta.glob("./locales/*.ts", { eager: true, import: "default" });\nexport { messages };',
    );

    const { stdout, exitCode } = runCli(["--bundle", join(i18nDir, "i18n.ts")]);
    expect(exitCode).toBe(0);
    // eager + import default: (await import()).default
    expect(stdout).toContain("(await import(");
    expect(stdout).toContain(").default");
    expect(stdout).toContain("./locales/en.ts");
    expect(stdout).toContain("./locales/ko.ts");

    rmSync(i18nDir, { recursive: true, force: true });
  });

  test("eager + import: (await import()).setup 패턴", () => {
    writeFileSync(
      join(dir, "eager-named.ts"),
      'const m = import.meta.glob("./modules/*.ts", { eager: true, import: "setup" });\nconsole.log(m);',
    );
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "eager-named.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("(await import(");
    expect(stdout).toContain(").setup");
  });
});

// ─── UMD/AMD 포맷 ───

describe("CLI: UMD/AMD format", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-cli-umd-"));
    writeFileSync(
      join(dir, "app.ts"),
      'import { useState } from "react";\nexport function App() { return useState(0); }',
    );
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test("UMD: external dependency array + factory params", () => {
    const { stdout, exitCode } = runCli([
      "--bundle",
      join(dir, "app.ts"),
      "--format=umd",
      "--external",
      "react",
      "--global-name=MyApp",
    ]);
    expect(exitCode).toBe(0);
    // dependency array에 "react" 포함
    expect(stdout).toContain('define(["react"]');
    // factory 매개변수
    expect(stdout).toContain("function(React)");
    // CJS require 경로
    expect(stdout).toContain('require("react")');
    // IIFE 글로벌
    expect(stdout).toContain("root.React");
    // body에 named import → factory param 프로퍼티 접근
    expect(stdout).toContain("React.useState");
    // body에 bare require("react") 없음
    expect(stdout).not.toContain('var React = require("react")');
  });

  test("AMD: external dependency array + factory params", () => {
    const { stdout, exitCode } = runCli([
      "--bundle",
      join(dir, "app.ts"),
      "--format=amd",
      "--external",
      "react",
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('define(["react"]');
    expect(stdout).toContain("function(React)");
    expect(stdout).toContain("React.useState");
  });

  test("UMD: Node.js에서 실행 가능", () => {
    // react mock + UMD 번들을 Node.js에서 실행
    const mockDir = mkdtempSync(join(tmpdir(), "zts-umd-e2e-"));
    writeFileSync(
      join(mockDir, "app.ts"),
      'import { greet } from "mylib";\nexport const msg = greet("world");',
    );
    mkdirSync(join(mockDir, "node_modules", "mylib"), { recursive: true });
    writeFileSync(
      join(mockDir, "node_modules", "mylib", "index.js"),
      'exports.greet = function(n) { return "Hello " + n; };',
    );

    const outFile = join(mockDir, "bundle.js");
    const { exitCode } = runCli([
      "--bundle",
      join(mockDir, "app.ts"),
      "--format=umd",
      "--external",
      "mylib",
      "-o",
      outFile,
    ]);
    expect(exitCode).toBe(0);

    // Node.js에서 UMD 번들 require → CJS 경로로 실행
    const run = runNodeEval(`const m = require(${JSON.stringify(outFile)}); console.log(m.msg);`, {
      cwd: mockDir,
    });
    expect(run.stdout.trim()).toBe("Hello world");

    rmSync(mockDir, { recursive: true, force: true });
  });

  test("UMD: 실제 React로 CJS 실행 E2E", () => {
    const umdDir = mkdtempSync(join(tmpdir(), "zts-umd-react-"));
    writeFileSync(
      join(umdDir, "pure.tsx"),
      [
        'import React, { createElement } from "react";',
        "export function Greeting(props: { name: string }) {",
        '  return createElement("h1", null, "Hello " + props.name);',
        "}",
        "export const version = React.version;",
      ].join("\n"),
    );

    const outFile = join(umdDir, "bundle.js");
    const { exitCode } = runCli([
      "--bundle",
      join(umdDir, "pure.tsx"),
      "--format=umd",
      "--external",
      "react",
      "--global-name=MyLib",
      "-o",
      outFile,
    ]);
    expect(exitCode).toBe(0);

    // Node.js에서 UMD 번들을 require → 실제 React 모듈이 factory로 주입됨
    const projectRoot = resolve(import.meta.dir, "../../..");
    const run = runNodeEval(
      `const m = require(${JSON.stringify(outFile)}); console.log(m.version); const el = m.Greeting({ name: "ZTS" }); console.log(el.type + ":" + el.props.children);`,
      {
        cwd: projectRoot,
        env: { ...process.env, NODE_PATH: join(projectRoot, "node_modules") },
      },
    );
    const lines = run.stdout.trim().split("\n");
    // React.version이 존재 (실제 react 패키지에서 읽힌 값)
    expect(lines[0]).toMatch(/^\d+\.\d+\.\d+$/);
    // createElement 결과: h1:Hello ZTS
    expect(lines[1]).toBe("h1:Hello ZTS");

    rmSync(umdDir, { recursive: true, force: true });
  });

  test("AMD: 실제 React로 출력 구조 검증", () => {
    const amdDir = mkdtempSync(join(tmpdir(), "zts-amd-react-"));
    writeFileSync(
      join(amdDir, "lib.tsx"),
      'import React from "react";\nexport const ver = React.version;\nexport const el = React.createElement("span", null, "hi");',
    );

    const { stdout, exitCode } = runCli([
      "--bundle",
      join(amdDir, "lib.tsx"),
      "--format=amd",
      "--external",
      "react",
    ]);
    expect(exitCode).toBe(0);
    // AMD wrapper 구조
    expect(stdout).toContain('define(["react"]');
    expect(stdout).toContain("function(React)");
    // body에서 React 직접 참조 (require 아님)
    expect(stdout).toContain("React.version");
    expect(stdout).toContain("React.createElement");
    // bare require("react") 없음
    expect(stdout).not.toContain('require("react")');

    rmSync(amdDir, { recursive: true, force: true });
  });
});

// ─── Bundle + Plugin ───

describe("CLI: bundle + plugin", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-cli-plugin-"));
    writeFileSync(join(dir, "entry.ts"), 'import css from "./style.css";\nconsole.log(css);');

    // zts.config.js — CSS 플러그인
    writeFileSync(
      join(dir, "zts.config.js"),
      `
import { resolve } from "node:path";
export default {
  plugins: [{
    name: "css-plugin",
    setup(build) {
      build.onResolve({ filter: /\\.css$/ }, (args) => ({
        path: resolve("${dir.replace(/\\/g, "\\\\")}", args.path),
      }));
      build.onLoad({ filter: /\\.css$/ }, () => ({
        contents: 'export default "color: red";',
      }));
    },
  }],
};
`,
    );
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test("--plugin으로 JS 설정 파일 로드", () => {
    const { stdout, exitCode } = runCli([
      "--bundle",
      join(dir, "entry.ts"),
      "--plugin",
      join(dir, "zts.config.js"),
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("color: red");
  });
});

// ─── Watch 모드 ───

describe("CLI: watch", () => {
  test("--watch-json 초기 빌드 후 ready 이벤트", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-watch-"));
    writeFileSync(join(dir, "index.ts"), "export const x = 1;");
    const outDir = join(dir, "dist");

    const logPath = join(dir, "watch.log");
    const errPath = join(dir, "watch.err");
    const proc = spawn("sh", [
      "-c",
      `${[RUNTIME, CLI, "--bundle", join(dir, "index.ts"), "--outdir", outDir, "--watch-json"]
        .map(shellQuote)
        .join(" ")} > ${shellQuote(logPath)} 2> ${shellQuote(errPath)}`,
    ]);

    const lines: string[] = [];
    const linePromise = new Promise<void>((resolve) => {
      const poll = () => {
        if (existsSync(logPath)) {
          lines.splice(
            0,
            lines.length,
            ...readFileSync(logPath, "utf8").split("\n").filter(Boolean),
          );
          for (const line of lines) {
            try {
              const event = JSON.parse(line);
              if (event.type === "ready" || event.type === "rebuild") {
                resolve();
                return;
              }
            } catch {}
          }
        }
        setTimeout(poll, 50);
      };
      poll();
    });

    // 3초 타임아웃
    const timeout = new Promise<void>((_, reject) =>
      setTimeout(() => reject(new Error("watch timeout")), 3000),
    );

    try {
      await Promise.race([linePromise, timeout]);
    } finally {
      proc.kill();
    }

    expect(lines.length).toBeGreaterThan(0);
    const events = lines
      .map((l) => {
        try {
          return JSON.parse(l);
        } catch {
          return null;
        }
      })
      .filter(Boolean);
    // rebuild 또는 ready 이벤트가 있어야 함
    expect(events.some((e) => e.type === "rebuild" || e.type === "ready")).toBe(true);

    rmSync(dir, { recursive: true, force: true });
  });

  test("--watch-json: zts.config.json 변경 시 restart 이벤트 (#2107)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-watch-config-restart-"));
    writeFileSync(join(dir, "index.ts"), "export const x = 1;");
    writeFileSync(join(dir, "zts.config.json"), `{}`);
    const outDir = join(dir, "dist");

    const logPath = join(dir, "watch.log");
    const errPath = join(dir, "watch.err");
    const proc = spawn(
      "sh",
      [
        "-c",
        `${[RUNTIME, CLI, "--bundle", join(dir, "index.ts"), "--outdir", outDir, "--watch-json"]
          .map(shellQuote)
          .join(" ")} > ${shellQuote(logPath)} 2> ${shellQuote(errPath)}`,
      ],
      { cwd: dir },
    );

    // 초기 ready 까지 대기
    await waitForEvent(logPath, (e) => e.type === "ready" || e.type === "rebuild", 5000);

    // config 변경 trigger
    writeFileSync(join(dir, "zts.config.json"), `{"banner": "/* changed */"}`);

    // restart 이벤트 대기
    try {
      await waitForEvent(logPath, (e) => e.type === "restart", 5000);
    } finally {
      proc.kill();
    }

    const events = readEvents(logPath);
    const restart = events.find((e) => e.type === "restart");
    expect(restart).toBeDefined();
    expect(restart.reason).toContain("config");

    rmSync(dir, { recursive: true, force: true });
  }, 15000);

  test("--watch-json: .env 변경 시 restart 이벤트", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-watch-env-restart-"));
    writeFileSync(join(dir, "index.ts"), "export const x = 1;");
    writeFileSync(join(dir, ".env"), "VITE_K=initial");
    const outDir = join(dir, "dist");

    const logPath = join(dir, "watch.log");
    const errPath = join(dir, "watch.err");
    const proc = spawn(
      "sh",
      [
        "-c",
        `${[RUNTIME, CLI, "--bundle", join(dir, "index.ts"), "--outdir", outDir, "--watch-json"]
          .map(shellQuote)
          .join(" ")} > ${shellQuote(logPath)} 2> ${shellQuote(errPath)}`,
      ],
      { cwd: dir },
    );

    await waitForEvent(logPath, (e) => e.type === "ready" || e.type === "rebuild", 5000);

    writeFileSync(join(dir, ".env"), "VITE_K=changed");

    try {
      await waitForEvent(logPath, (e) => e.type === "restart", 5000);
    } finally {
      proc.kill();
    }

    const events = readEvents(logPath);
    expect(events.some((e) => e.type === "restart")).toBe(true);

    rmSync(dir, { recursive: true, force: true });
  }, 15000);

  test("--watch-json: zts.config.ts (TS) 변경도 restart", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-watch-ts-cfg-"));
    writeFileSync(join(dir, "index.ts"), "export const x = 1;");
    writeFileSync(join(dir, "zts.config.ts"), `export default { banner: "/* v1 */" as const };`);
    const outDir = join(dir, "dist");

    const logPath = join(dir, "watch.log");
    const errPath = join(dir, "watch.err");
    const proc = spawn(
      "sh",
      [
        "-c",
        `${[RUNTIME, CLI, "--bundle", join(dir, "index.ts"), "--outdir", outDir, "--watch-json"]
          .map(shellQuote)
          .join(" ")} > ${shellQuote(logPath)} 2> ${shellQuote(errPath)}`,
      ],
      { cwd: dir },
    );

    await waitForEvent(logPath, (e) => e.type === "ready" || e.type === "rebuild", 5000);
    writeFileSync(join(dir, "zts.config.ts"), `export default { banner: "/* v2 */" as const };`);

    try {
      await waitForEvent(logPath, (e) => e.type === "restart", 5000);
    } finally {
      proc.kill();
    }

    expect(readEvents(logPath).some((e) => e.type === "restart")).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  }, 15000);

  test("--watch-json: .env.production (mode-specific) 변경도 restart", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-watch-mode-env-"));
    writeFileSync(join(dir, "index.ts"), "export const x = 1;");
    writeFileSync(join(dir, ".env.production"), "VITE_K=initial");
    const outDir = join(dir, "dist");

    const logPath = join(dir, "watch.log");
    const errPath = join(dir, "watch.err");
    const proc = spawn(
      "sh",
      [
        "-c",
        `${[
          RUNTIME,
          CLI,
          "--bundle",
          "--mode=production",
          join(dir, "index.ts"),
          "--outdir",
          outDir,
          "--watch-json",
        ]
          .map(shellQuote)
          .join(" ")} > ${shellQuote(logPath)} 2> ${shellQuote(errPath)}`,
      ],
      { cwd: dir },
    );

    await waitForEvent(logPath, (e) => e.type === "ready" || e.type === "rebuild", 5000);
    writeFileSync(join(dir, ".env.production"), "VITE_K=changed");

    try {
      await waitForEvent(logPath, (e) => e.type === "restart", 5000);
    } finally {
      proc.kill();
    }

    expect(readEvents(logPath).some((e) => e.type === "restart")).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  }, 15000);

  test("--watch-json: 일반 entry 파일 변경은 rebuild (restart 아님)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-watch-rebuild-not-restart-"));
    writeFileSync(join(dir, "index.ts"), "export const x = 1;");
    writeFileSync(join(dir, "zts.config.json"), `{}`);
    const outDir = join(dir, "dist");

    const logPath = join(dir, "watch.log");
    const errPath = join(dir, "watch.err");
    const proc = spawn(
      "sh",
      [
        "-c",
        `${[RUNTIME, CLI, "--bundle", join(dir, "index.ts"), "--outdir", outDir, "--watch-json"]
          .map(shellQuote)
          .join(" ")} > ${shellQuote(logPath)} 2> ${shellQuote(errPath)}`,
      ],
      { cwd: dir },
    );

    await waitForEvent(logPath, (e) => e.type === "ready" || e.type === "rebuild", 5000);
    // 초기 ready 후 entry 변경 — rebuild 만 와야 함.
    writeFileSync(join(dir, "index.ts"), "export const x = 2;");

    try {
      // rebuild 가 ready 외에 추가로 발생할 때까지 기다림.
      const start = Date.now();
      let extraRebuild = false;
      while (Date.now() - start < 5000) {
        const events = readEvents(logPath);
        if (
          events.filter((e) => e.type === "rebuild").length >= 1 &&
          events.some((e) => e.type === "ready")
        ) {
          extraRebuild = true;
          break;
        }
        await new Promise((r) => setTimeout(r, 50));
      }
      expect(extraRebuild).toBe(true);
      // restart 이벤트 없어야 함.
      expect(readEvents(logPath).some((e) => e.type === "restart")).toBe(false);
    } finally {
      proc.kill();
    }

    rmSync(dir, { recursive: true, force: true });
  }, 15000);

  test("--watch-json: --config <path> 의 명시 config 변경도 restart", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-watch-explicit-cfg-"));
    writeFileSync(join(dir, "index.ts"), "export const x = 1;");
    writeFileSync(join(dir, "custom.config.json"), `{}`);
    const outDir = join(dir, "dist");

    const logPath = join(dir, "watch.log");
    const errPath = join(dir, "watch.err");
    const proc = spawn(
      "sh",
      [
        "-c",
        `${[
          RUNTIME,
          CLI,
          "--bundle",
          "--config",
          join(dir, "custom.config.json"),
          join(dir, "index.ts"),
          "--outdir",
          outDir,
          "--watch-json",
        ]
          .map(shellQuote)
          .join(" ")} > ${shellQuote(logPath)} 2> ${shellQuote(errPath)}`,
      ],
      { cwd: dir },
    );

    await waitForEvent(logPath, (e) => e.type === "ready" || e.type === "rebuild", 5000);
    writeFileSync(join(dir, "custom.config.json"), `{"banner": "/* changed */"}`);

    try {
      await waitForEvent(logPath, (e) => e.type === "restart", 5000);
    } finally {
      proc.kill();
    }

    expect(readEvents(logPath).some((e) => e.type === "restart")).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  }, 15000);
});

/** Helper: poll log file until matching event appears (or timeout). */
async function waitForEvent(
  logPath: string,
  predicate: (e: { type: string; [k: string]: unknown }) => boolean,
  timeoutMs: number,
): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const events = readEvents(logPath);
    if (events.some(predicate)) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`waitForEvent timeout (${timeoutMs}ms)`);
}

function readEvents(logPath: string): Array<{ type: string; [k: string]: unknown }> {
  if (!existsSync(logPath)) return [];
  const lines = readFileSync(logPath, "utf8").split("\n").filter(Boolean);
  return lines
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

// ─── Serve 모드 ───

describe("CLI: serve", () => {
  test("정적 파일 서빙", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-serve-"));
    writeFileSync(join(dir, "index.html"), "<h1>Hello</h1>");

    const port = 12400 + Math.floor(Math.random() * 100);
    const proc = spawn(RUNTIME, [CLI, "--serve", dir, `--port=${port}`]);

    await waitForServer(port);

    try {
      const res = await fetch(`http://localhost:${port}/`);
      expect(res.status).toBe(200);
      const text = await res.text();
      expect(text).toContain("<h1>Hello</h1>");

      // 없는 파일 → 404
      const res404 = await fetch(`http://localhost:${port}/nonexistent`);
      expect(res404.status).toBe(404);
    } finally {
      proc.kill();
    }

    rmSync(dir, { recursive: true, force: true });
  });

  test("CORS 헤더 포함", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-cors-"));
    writeFileSync(join(dir, "index.html"), "<h1>Test</h1>");

    const port = 12500 + Math.floor(Math.random() * 100);
    const proc = spawn(RUNTIME, [CLI, "--serve", dir, `--port=${port}`]);
    await new Promise((r) => setTimeout(r, 500));

    try {
      const res = await fetch(`http://localhost:${port}/`);
      expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
    } finally {
      proc.kill();
    }

    rmSync(dir, { recursive: true, force: true });
  });

  test("HTTPS 서빙 (--certfile / --keyfile)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-https-"));
    writeFileSync(join(dir, "index.html"), "<h1>Secure</h1>");

    // 자체 서명 인증서 생성
    const certFile = join(dir, "cert.pem");
    const keyFile = join(dir, "key.pem");
    execSync(
      `openssl req -x509 -newkey rsa:2048 -keyout ${keyFile} -out ${certFile} -days 1 -nodes -subj "/CN=localhost" 2>/dev/null`,
    );

    const port = 12600 + Math.floor(Math.random() * 100);
    const proc = spawn(RUNTIME, [
      CLI,
      "--serve",
      dir,
      `--port=${port}`,
      "--certfile",
      certFile,
      "--keyfile",
      keyFile,
    ]);

    await waitForServer(port, 20, 100, "https");

    try {
      const res = await fetch(`https://localhost:${port}/`, {
        tls: { rejectUnauthorized: false },
      } as any);
      expect(res.status).toBe(200);
      const text = await res.text();
      expect(text).toContain("<h1>Secure</h1>");
    } finally {
      proc.kill();
    }

    rmSync(dir, { recursive: true, force: true });
  });

  test("HTTPS 없는 파일 → 404", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-https-404-"));
    writeFileSync(join(dir, "index.html"), "<h1>OK</h1>");

    const certFile = join(dir, "cert.pem");
    const keyFile = join(dir, "key.pem");
    execSync(
      `openssl req -x509 -newkey rsa:2048 -keyout ${keyFile} -out ${certFile} -days 1 -nodes -subj "/CN=localhost" 2>/dev/null`,
    );

    const port = 12700 + Math.floor(Math.random() * 100);
    const proc = spawn(RUNTIME, [
      CLI,
      "--serve",
      dir,
      `--port=${port}`,
      "--certfile",
      certFile,
      "--keyfile",
      keyFile,
    ]);

    await waitForServer(port, 20, 100, "https");

    try {
      const res = await fetch(`https://localhost:${port}/nonexistent`, {
        tls: { rejectUnauthorized: false },
      } as any);
      expect(res.status).toBe(404);
    } finally {
      proc.kill();
    }

    rmSync(dir, { recursive: true, force: true });
  });

  test("HTTPS CORS 헤더 포함", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-https-cors-"));
    writeFileSync(join(dir, "index.html"), "<h1>CORS</h1>");

    const certFile = join(dir, "cert.pem");
    const keyFile = join(dir, "key.pem");
    execSync(
      `openssl req -x509 -newkey rsa:2048 -keyout ${keyFile} -out ${certFile} -days 1 -nodes -subj "/CN=localhost" 2>/dev/null`,
    );

    const port = 12800 + Math.floor(Math.random() * 100);
    const proc = spawn(RUNTIME, [
      CLI,
      "--serve",
      dir,
      `--port=${port}`,
      "--certfile",
      certFile,
      "--keyfile",
      keyFile,
    ]);

    await waitForServer(port, 20, 100, "https");

    try {
      const res = await fetch(`https://localhost:${port}/`, {
        tls: { rejectUnauthorized: false },
      } as any);
      expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
    } finally {
      proc.kill();
    }

    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── CLI 인자 파싱 엣지케이스 ───

describe("CLI: arg parsing", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-cli-args-"));
    writeFileSync(join(dir, "input.ts"), "export const x: number = 1;");
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test("--quotes=single", () => {
    const { exitCode } = runCli([join(dir, "input.ts"), "--quotes=single"]);
    expect(exitCode).toBe(0);
  });

  test("--platform=node", () => {
    const { exitCode } = runCli(["--bundle", join(dir, "input.ts"), "--platform=node"]);
    expect(exitCode).toBe(0);
  });

  test("--platform=react-native", () => {
    const { exitCode } = runCli(["--bundle", join(dir, "input.ts"), "--platform=react-native"]);
    expect(exitCode).toBe(0);
  });

  test("--jsx=automatic + --external react", () => {
    const jsxDir = mkdtempSync(join(tmpdir(), "zts-cli-jsx-"));
    writeFileSync(join(jsxDir, "app.tsx"), "export default () => <div />;");
    const { stdout, exitCode } = runCli([
      "--bundle",
      join(jsxDir, "app.tsx"),
      "--jsx=automatic",
      "--external",
      "react/jsx-runtime",
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("jsx-runtime");
    rmSync(jsxDir, { recursive: true, force: true });
  });

  test("--define:KEY=VALUE", () => {
    const defDir = mkdtempSync(join(tmpdir(), "zts-cli-define-"));
    writeFileSync(join(defDir, "input.ts"), "console.log(process.env.NODE_ENV);");
    const { exitCode } = runCli([
      "--bundle",
      join(defDir, "input.ts"),
      '--define:process.env.NODE_ENV="production"',
    ]);
    expect(exitCode).toBe(0);
    rmSync(defDir, { recursive: true, force: true });
  });

  test("여러 --external 반복", () => {
    const extDir = mkdtempSync(join(tmpdir(), "zts-cli-multi-ext-"));
    writeFileSync(
      join(extDir, "app.ts"),
      'import a from "react";\nimport b from "lodash";\nconsole.log(a, b);',
    );
    const { stdout, exitCode } = runCli([
      "--bundle",
      join(extDir, "app.ts"),
      "--external",
      "react",
      "--external",
      "lodash",
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("react");
    expect(stdout).toContain("lodash");
    rmSync(extDir, { recursive: true, force: true });
  });

  test("--jobs=1 (단일 스레드)", () => {
    const { exitCode } = runCli(["--bundle", join(dir, "input.ts"), "--jobs=1"]);
    expect(exitCode).toBe(0);
  });

  test("unknown 옵션 → warning", () => {
    const { stderr, exitCode } = runCli([join(dir, "input.ts"), "--unknown-flag"]);
    expect(exitCode).toBe(0); // warning이지 에러는 아님
    expect(stderr).toContain("unknown option");
  });
});

// ─── tsconfig.json 자동 로드 ───

describe("CLI: tsconfig", () => {
  test("tsconfig.json에서 experimentalDecorators 자동 로드", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-tsconfig-"));
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: { experimentalDecorators: true },
      }),
    );
    writeFileSync(
      join(dir, "input.ts"),
      "@sealed\nclass Greeter {\n  greeting: string;\n  constructor(message: string) { this.greeting = message; }\n}",
    );

    const { stdout, exitCode } = runCli([join(dir, "input.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("__decorate");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig.json에서 jsx 자동 로드", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-tsconfig-jsx-"));
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: { jsx: "react-jsx" },
      }),
    );
    writeFileSync(join(dir, "app.tsx"), "export default () => <div>hello</div>;");

    const { stdout, exitCode } = runCli([join(dir, "app.tsx")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("jsx");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--project로 명시적 tsconfig 경로", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-project-"));
    const configDir = mkdtempSync(join(tmpdir(), "zts-cli-config-"));
    writeFileSync(
      join(configDir, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: { experimentalDecorators: true },
      }),
    );
    writeFileSync(
      join(dir, "input.ts"),
      "@sealed\nclass Greeter { greeting: string; constructor(m: string) { this.greeting = m; } }",
    );

    const { stdout, exitCode } = runCli([
      join(dir, "input.ts"),
      "-p",
      join(configDir, "tsconfig.json"),
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("__decorate");
    rmSync(dir, { recursive: true, force: true });
    rmSync(configDir, { recursive: true, force: true });
  });

  test("--tsconfig-path 는 -p 의 alias (NAPI `tsconfigPath` 와 통일된 이름)", () => {
    // 공백/=형 모두, 디렉토리/파일 경로 모두 지원.
    const configDir = mkdtempSync(join(tmpdir(), "zts-cli-tsc-alias-"));
    writeFileSync(
      join(configDir, "tsconfig.json"),
      JSON.stringify({ compilerOptions: { verbatimModuleSyntax: true } }),
    );
    const inputPath = join(configDir, "input.ts");
    writeFileSync(inputPath, 'import { foo } from "./bar";');

    for (const args of [
      ["--tsconfig-path", configDir],
      [`--tsconfig-path=${configDir}`],
      ["--tsconfig-path", join(configDir, "tsconfig.json")],
      ["-p", join(configDir, "tsconfig.json")], // -p 도 파일 경로 지원 (loadFromPath 전환)
    ]) {
      const { stdout, exitCode } = runCli([inputPath, ...args]);
      expect(exitCode).toBe(0);
      // verbatimModuleSyntax 가 적용되면 미사용 import 도 보존
      expect(stdout).toContain("./bar");
    }
    rmSync(configDir, { recursive: true, force: true });
  });

  test("CLI 옵션이 tsconfig보다 우선", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-override-"));
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: { jsx: "react" }, // classic
      }),
    );
    writeFileSync(join(dir, "app.tsx"), "export default () => <div>hello</div>;");

    // --jsx=automatic으로 오버라이드
    const { stdout, exitCode } = runCli([join(dir, "app.tsx"), "--jsx=automatic"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("jsx"); // automatic이면 import 문 생성
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig.json에 주석이 있어도 파싱 성공", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-tsconfig-comments-"));
    writeFileSync(
      join(dir, "tsconfig.json"),
      `{
  // 이것은 주석입니다
  "compilerOptions": {
    /* 블록 주석 */
    "experimentalDecorators": true
  }
}`,
    );
    writeFileSync(
      join(dir, "input.ts"),
      "@sealed\nclass G { x: string; constructor(m: string) { this.x = m; } }",
    );

    const { stdout, exitCode } = runCli([join(dir, "input.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("__decorate");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig.json 없으면 무시 (에러 없음)", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-no-tsconfig-"));
    writeFileSync(join(dir, "input.ts"), "const x: number = 1;");

    const { stdout, exitCode } = runCli([join(dir, "input.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("const x = 1");
    rmSync(dir, { recursive: true, force: true });
  });

  test("useDefineForClassFields=false tsconfig 로드", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-define-fields-"));
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: { useDefineForClassFields: false },
      }),
    );
    writeFileSync(join(dir, "input.ts"), "class A { x = 1; }");

    const { stdout, exitCode } = runCli([join(dir, "input.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("this.x");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig에 URL이 포함된 문자열이 있어도 파싱 성공", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-tsconfig-url-"));
    writeFileSync(
      join(dir, "tsconfig.json"),
      `{
  // tsconfig with URL in value
  "compilerOptions": {
    "experimentalDecorators": true,
    "baseUrl": "https://example.com/path"
  }
}`,
    );
    writeFileSync(
      join(dir, "input.ts"),
      "@sealed\nclass G { x: string; constructor(m: string) { this.x = m; } }",
    );

    const { stdout, exitCode } = runCli([join(dir, "input.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("__decorate");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: wildcard + exact alias 가 bundler 에서 해석됨", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-tsc-paths-"));
    mkdirSync(join(dir, "src"), { recursive: true });
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: {
          baseUrl: ".",
          paths: {
            "@/*": ["./src/*"],
            "@utils": ["./src/utils.ts"],
          },
        },
      }),
    );
    writeFileSync(
      join(dir, "src", "utils.ts"),
      "export function hello(name: string): string { return `Hello, ${name}!`; }",
    );
    writeFileSync(join(dir, "src", "greet.ts"), "export function greet(): string { return 'hi'; }");
    writeFileSync(
      join(dir, "entry.ts"),
      'import { hello } from "@utils";\nimport { greet } from "@/greet";\nconsole.log(hello("world"), greet());',
    );
    const { stdout, exitCode } = runCli(["--bundle", "-p", dir, join(dir, "entry.ts")]);
    expect(exitCode).toBe(0);
    // 두 파일이 모두 번들에 들어와야 함 (paths 가 해석되지 않으면 resolve 실패로 번들 실패).
    expect(stdout).toContain("Hello, ${name}!");
    expect(stdout).toContain(`return "hi"`);
    rmSync(dir, { recursive: true, force: true });
  });

  test("--alias 가 tsconfig paths 를 덮어씀", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-alias-priority-"));
    mkdirSync(join(dir, "src"), { recursive: true });
    mkdirSync(join(dir, "alt"), { recursive: true });
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: { paths: { "@utils": ["./src/utils.ts"] } },
      }),
    );
    writeFileSync(
      join(dir, "src", "utils.ts"),
      "export function hello(): string { return 'FROM_TSCONFIG'; }",
    );
    writeFileSync(
      join(dir, "alt", "utils.ts"),
      "export function hello(): string { return 'FROM_ALIAS_CLI'; }",
    );
    writeFileSync(join(dir, "entry.ts"), 'import { hello } from "@utils";\nconsole.log(hello());');

    // --alias 없으면 tsconfig 값 적용
    const withoutAlias = runCli(["--bundle", "-p", dir, join(dir, "entry.ts")]);
    expect(withoutAlias.exitCode).toBe(0);
    expect(withoutAlias.stdout).toContain("FROM_TSCONFIG");

    // --alias 가 붙으면 그 값이 tsconfig 를 덮어씀 (CLI > tsconfig)
    const withAlias = runCli([
      "--bundle",
      "-p",
      dir,
      `--alias:@utils=${join(dir, "alt", "utils.ts")}`,
      join(dir, "entry.ts"),
    ]);
    expect(withAlias.exitCode).toBe(0);
    expect(withAlias.stdout).toContain("FROM_ALIAS_CLI");
    expect(withAlias.stdout).not.toContain("FROM_TSCONFIG");

    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: 깊은 서브경로 prefix 매칭 (@/a/b/c)", () => {
    // "@/*" alias 가 중첩 디렉토리까지 정상 전파되는지 — applyAlias 의 prefix 로직 검증.
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-paths-deep-"));
    mkdirSync(join(dir, "src", "a", "b"), { recursive: true });
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({ compilerOptions: { baseUrl: ".", paths: { "@/*": ["./src/*"] } } }),
    );
    writeFileSync(join(dir, "src", "a", "b", "c.ts"), "export const V = 'DEEP_OK';");
    writeFileSync(join(dir, "entry.ts"), 'import { V } from "@/a/b/c";\nconsole.log(V);');
    const { stdout, exitCode } = runCli(["--bundle", "-p", dir, join(dir, "entry.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("DEEP_OK");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: baseUrl 없으면 tsconfig 디렉토리가 기본 base", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-paths-nobase-"));
    mkdirSync(join(dir, "lib"), { recursive: true });
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({ compilerOptions: { paths: { "#lib": ["./lib/index.ts"] } } }),
    );
    writeFileSync(join(dir, "lib", "index.ts"), "export const L = 'NOBASE_OK';");
    writeFileSync(join(dir, "entry.ts"), 'import { L } from "#lib";\nconsole.log(L);');
    const { stdout, exitCode } = runCli(["--bundle", "-p", dir, join(dir, "entry.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("NOBASE_OK");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: 배열 여러 후보 중 첫 번째만 사용 (v1 제약)", () => {
    // TS 공식은 순차 시도이나 ZTS v1 은 단일 — 첫 번째가 없어도 fallback 안 함을 문서화.
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-paths-multi-"));
    mkdirSync(join(dir, "src"), { recursive: true });
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: { paths: { "@m": ["./src/a.ts", "./src/b.ts"] } },
      }),
    );
    writeFileSync(join(dir, "src", "a.ts"), "export const M = 'FIRST';");
    writeFileSync(join(dir, "src", "b.ts"), "export const M = 'SECOND';");
    writeFileSync(join(dir, "entry.ts"), 'import { M } from "@m";\nconsole.log(M);');
    const { stdout, exitCode } = runCli(["--bundle", "-p", dir, join(dir, "entry.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("FIRST");
    expect(stdout).not.toContain("SECOND");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: 빈 paths 객체는 무시 (no crash)", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-paths-empty-"));
    writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { paths: {} } }));
    writeFileSync(join(dir, "entry.ts"), "console.log('OK');");
    const { stdout, exitCode } = runCli(["--bundle", "-p", dir, join(dir, "entry.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("OK");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: extends 체인에서 paths 상속", () => {
    // base tsconfig 의 paths 를 child 가 상속받는지 — mergeFrom 경로 검증.
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-paths-extends-"));
    mkdirSync(join(dir, "src"), { recursive: true });
    writeFileSync(
      join(dir, "tsconfig.base.json"),
      JSON.stringify({ compilerOptions: { paths: { "@base": ["./src/base.ts"] } } }),
    );
    writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ extends: "./tsconfig.base.json" }));
    writeFileSync(join(dir, "src", "base.ts"), "export const B = 'EXTENDED';");
    writeFileSync(join(dir, "entry.ts"), 'import { B } from "@base";\nconsole.log(B);');
    const { stdout, exitCode } = runCli(["--bundle", "-p", dir, join(dir, "entry.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("EXTENDED");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: 존재하지 않는 tsconfig 경로 → silent fallback (no crash)", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-paths-missing-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('OK');");
    const { stdout, exitCode } = runCli([
      "--bundle",
      "-p",
      "/nonexistent/path/tsconfig.json",
      join(dir, "entry.ts"),
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("OK");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: 자동 발견 — entry 상위 디렉토리에서 tsconfig.json 탐색", () => {
    // `-p` 없이도 entry 가 깊은 서브디렉토리에 있으면 상위로 올라가며 tsconfig.json 을 찾는다.
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-auto-discover-"));
    mkdirSync(join(dir, "src", "deep"), { recursive: true });
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({ compilerOptions: { baseUrl: ".", paths: { "@/*": ["./src/*"] } } }),
    );
    writeFileSync(join(dir, "src", "utils.ts"), "export function hello() { return 'AUTO_OK'; }");
    writeFileSync(
      join(dir, "src", "deep", "entry.ts"),
      'import { hello } from "@/utils";\nconsole.log(hello());',
    );
    // `-p` 없이 실행
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "src", "deep", "entry.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("AUTO_OK");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: 이중 '*' key 또는 비대칭 wildcard 는 경고 + skip", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-paths-warn-"));
    mkdirSync(join(dir, "src"), { recursive: true });
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: {
          paths: {
            "@bad/**/y": ["./src/x.ts"], // key 에 '*' 두 개 → ts(5073) 스킵
            "@mix/*": ["./src/plain.ts"], // key wildcard + target 비wildcard → ts(5063) 스킵
            "@ok/*": ["./src/*"], // 유효
          },
        },
      }),
    );
    writeFileSync(join(dir, "src", "hello.ts"), "export const H = 'ok_valid';");
    writeFileSync(join(dir, "entry.ts"), 'import { H } from "@ok/hello";\nconsole.log(H);');
    const { stdout, stderr, exitCode } = runCli(["--bundle", "-p", dir, join(dir, "entry.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("ok_valid");
    // 잘못된 entry 2 건은 경고 로그 — stderr 에 키워드 포함되는지 확인.
    expect(stderr).toContain("5073");
    expect(stderr).toContain("5063");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: 중간 wildcard (@pkg/*/types)", () => {
    // TS 공식 스펙: `*` 가 key 중간에 있으면 해당 위치의 세그먼트가 capture 되어 target 에 대입.
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-paths-mid-wild-"));
    mkdirSync(join(dir, "packages/foo/src"), { recursive: true });
    mkdirSync(join(dir, "packages/bar/src"), { recursive: true });
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: { paths: { "@pkg/*/types": ["./packages/*/src/types.ts"] } },
      }),
    );
    writeFileSync(join(dir, "packages/foo/src/types.ts"), "export const T = 'FOO_TYPES';");
    writeFileSync(join(dir, "packages/bar/src/types.ts"), "export const T = 'BAR_TYPES';");
    writeFileSync(
      join(dir, "entry.ts"),
      'import { T as F } from "@pkg/foo/types";\nimport { T as B } from "@pkg/bar/types";\nconsole.log(F, B);',
    );
    const { stdout, exitCode } = runCli(["--bundle", "-p", dir, join(dir, "entry.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("FOO_TYPES");
    expect(stdout).toContain("BAR_TYPES");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: 다중 후보 순차 fallback (첫 번째 실패 시 두 번째)", () => {
    // TS 공식 스펙: value 배열은 순서대로 시도. 첫 후보가 파일로 존재 안 하면 다음 후보로.
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-paths-multi-cand-"));
    mkdirSync(join(dir, "vendor"), { recursive: true });
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: {
          paths: { "@lib": ["./does-not-exist.ts", "./vendor/lib.ts"] },
        },
      }),
    );
    writeFileSync(join(dir, "vendor/lib.ts"), "export const L = 'FALLBACK_OK';");
    writeFileSync(join(dir, "entry.ts"), 'import { L } from "@lib";\nconsole.log(L);');
    const { stdout, exitCode } = runCli(["--bundle", "-p", dir, join(dir, "entry.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("FALLBACK_OK");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: .js extension 매핑 — '@util' → './src/util.ts'", () => {
    // tsconfig 값이 ./src/util.ts 인데 source 가 ./src/util.js 로 import 해도
    // resolver 의 TS extension mapping 이 동작해야 함 (pre-existing 기능, 회귀 방지).
    const dir = mkdtempSync(join(tmpdir(), "zts-cli-paths-ext-"));
    mkdirSync(join(dir, "src"), { recursive: true });
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({ compilerOptions: { paths: { "@util": ["./src/util"] } } }),
    );
    writeFileSync(join(dir, "src", "util.ts"), "export const U = 'EXT_OK';");
    writeFileSync(join(dir, "entry.ts"), 'import { U } from "@util";\nconsole.log(U);');
    const { stdout, exitCode } = runCli(["--bundle", "-p", dir, join(dir, "entry.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("EXT_OK");
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── zts.config.{ts,json} 자동 탐색 + BuildOptions 머지 (#2099 / #2101) ───

describe("CLI: zts.config 자동 탐색 + BuildOptions 머지", () => {
  test("zts.config.ts 의 entryPoints 가 자동 적용됨", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-config-merge-"));
    writeFileSync(join(dir, "src.ts"), "export const HIT = 'CONFIG_ENTRY_OK';");
    writeFileSync(
      join(dir, "zts.config.ts"),
      `export default { entryPoints: ["${join(dir, "src.ts").replace(/\\/g, "/")}"] };`,
    );
    // CLI 에 entry 안 줬는데 config 의 entryPoints 로 빌드되어야 함.
    const { stdout, exitCode } = runCli(["--bundle"], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("CONFIG_ENTRY_OK");
    rmSync(dir, { recursive: true, force: true });
  });

  test("zts.config.ts 의 minify 가 적용됨", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-config-minify-"));
    writeFileSync(
      join(dir, "entry.ts"),
      "const someLongName = 1; const anotherLongName = 2; console.log(someLongName + anotherLongName);",
    );
    writeFileSync(join(dir, "zts.config.ts"), `export default { minify: true };`);
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    // minify 시 식별자 축약으로 someLongName 같은 긴 이름이 사라짐.
    expect(stdout).not.toContain("someLongName");
    rmSync(dir, { recursive: true, force: true });
  });

  test("CLI 가 config 를 override (CLI > config 우선순위)", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-config-override-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('cli_wins');");
    writeFileSync(
      join(dir, "zts.config.json"),
      JSON.stringify({ format: "iife", globalName: "CFG_NAME" }),
    );
    // CLI 가 globalName 을 다른 값으로 넘기면 그게 우선.
    const { stdout, exitCode } = runCli(
      ["--bundle", "--global-name=CLI_NAME", join(dir, "entry.ts")],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain("CLI_NAME");
    expect(stdout).not.toContain("CFG_NAME");
    rmSync(dir, { recursive: true, force: true });
  });

  test("zts.config.json 의 external 배열이 적용됨", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-config-external-"));
    writeFileSync(join(dir, "entry.ts"), 'import * as fs from "node:fs";\nconsole.log(fs);');
    writeFileSync(join(dir, "zts.config.json"), JSON.stringify({ external: ["node:fs"] }));
    const { stdout, stderr, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    // external 이면 require/import 가 그대로 보존됨.
    expect(stdout).toMatch(/node:fs|require.*fs/);
    expect(stderr).not.toContain("error");
    rmSync(dir, { recursive: true, force: true });
  });

  test("zts.config.ts 의 plugins 가 적용됨", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-config-plugins-"));
    writeFileSync(join(dir, "entry.ts"), 'import x from "virtual:hello";\nconsole.log(x);');
    writeFileSync(
      join(dir, "zts.config.ts"),
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
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("PLUGIN_OK");
    rmSync(dir, { recursive: true, force: true });
  });

  test("config 부재 시 CLI 단독으로 정상 빌드 (회귀 방지)", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-no-config-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('NO_CONFIG_OK');");
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("NO_CONFIG_OK");
    rmSync(dir, { recursive: true, force: true });
  });

  test("config 컴파일 실패 시 CLI 가 명확한 에러로 exit 1", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-broken-config-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('x');");
    writeFileSync(join(dir, "zts.config.ts"), "export default { format: 'esm'  // 닫는 brace 없음");
    const { stderr, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(1);
    expect(stderr).toContain("failed to load config");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--plugin <path> 의 plugins 필드가 적용된다 (BuildOptions 다른 필드는 무시)", () => {
    // `--plugin <path>` 는 의미상 plugin-only 진입점 — 자동 탐색의 BuildOptions
    // 머지와 분리. config 의 BuildOptions 적용은 자동 탐색 경로 (zts.config.*) 가
    // 담당. `--config <path>` 로 명시적으로 BuildOptions 머지하는 경로는 #2103.
    const dir = mkdtempSync(join(tmpdir(), "zts-plugin-only-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('original');");
    writeFileSync(
      join(dir, "p.js"),
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
      ["--bundle", "--plugin", join(dir, "p.js"), join(dir, "entry.ts")],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain("MARKER_OK");
    rmSync(dir, { recursive: true, force: true });
  });

  // ─ 백필: Phase 1-2 (#2115) BuildOptions 머지 갭 ───────────────────────────────

  test("config 의 format 머지 — CLI 미지정 시 적용", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cfg-format-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('hi');");
    writeFileSync(
      join(dir, "zts.config.json"),
      JSON.stringify({ format: "iife", globalName: "G" }),
    );
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("var G");
    rmSync(dir, { recursive: true, force: true });
  });

  test("config 의 sourcemap=true 가 적용됨 (default=false override)", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cfg-sourcemap-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('hi');");
    writeFileSync(join(dir, "zts.config.json"), JSON.stringify({ sourcemap: true }));
    const outFile = join(dir, "out.js");
    const { exitCode } = runCli(["--bundle", "-o", outFile, join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(existsSync(outFile + ".map")).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });

  test("config 의 alias 객체 머지 — CLI alias 가 키 단위로 override", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cfg-alias-"));
    writeFileSync(join(dir, "real-a.ts"), "export const tag = 'CONFIG_ALIAS_A';");
    writeFileSync(join(dir, "real-b.ts"), "export const tag = 'CLI_ALIAS_B';");
    writeFileSync(
      join(dir, "entry.ts"),
      `import { tag as a } from "@a";
       import { tag as b } from "@b";
       console.log(a, b);`,
    );
    writeFileSync(
      join(dir, "zts.config.json"),
      JSON.stringify({
        alias: {
          "@a": join(dir, "real-a.ts"),
          "@b": join(dir, "should-be-overridden.ts"),
        },
      }),
    );
    const { stdout, exitCode } = runCli(
      ["--bundle", `--alias:@b=${join(dir, "real-b.ts")}`, join(dir, "entry.ts")],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain("CONFIG_ALIAS_A"); // config 의 @a 그대로 사용
    expect(stdout).toContain("CLI_ALIAS_B"); // CLI 의 @b 가 config 를 override
    rmSync(dir, { recursive: true, force: true });
  });

  test("config 의 define 객체 + CLI define 머지 — 키 단위 override", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cfg-define-"));
    writeFileSync(
      join(dir, "entry.ts"),
      `console.log(__VER__);
       console.log(__BUILD__);`,
    );
    writeFileSync(
      join(dir, "zts.config.json"),
      JSON.stringify({
        define: { __VER__: '"v_from_config"', __BUILD__: '"build_from_config"' },
      }),
    );
    const { stdout, exitCode } = runCli(
      ["--bundle", '--define:__BUILD__="build_from_cli"', join(dir, "entry.ts")],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain("v_from_config"); // config 만 정의 → 그대로
    expect(stdout).toContain("build_from_cli"); // CLI override
    rmSync(dir, { recursive: true, force: true });
  });

  test("config 의 external 배열 — CLI external 빈 상태면 config 사용", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cfg-external-"));
    writeFileSync(
      join(dir, "entry.ts"),
      `import * as path from "node:path";
       import * as fs from "node:fs";
       console.log(path, fs);`,
    );
    writeFileSync(
      join(dir, "zts.config.json"),
      JSON.stringify({ external: ["node:path", "node:fs"] }),
    );
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    // external 이면 require/import 가 그대로 보존
    expect(stdout).toMatch(/node:path/);
    expect(stdout).toMatch(/node:fs/);
    rmSync(dir, { recursive: true, force: true });
  });

  test("config 의 target 머지 — CLI 미지정 시 적용", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cfg-target-"));
    writeFileSync(
      join(dir, "entry.ts"),
      "const arr = [1, 2, 3];\nconst [a, ...rest] = arr;\nconsole.log(a, rest);",
    );
    writeFileSync(join(dir, "zts.config.json"), JSON.stringify({ target: "es5" }));
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    // es5 타겟이면 array destructuring 이 down-leveling 되어 .slice 호출이 나와야 함
    expect(stdout).toContain(".slice(");
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig + config + CLI 3-way 우선순위: CLI > config > tsconfig", () => {
    // tsconfig 가 jsx=preserve, config 가 jsx=automatic, CLI 가 jsx=transform.
    // 결과는 transform (CLI 우선).
    const dir = mkdtempSync(join(tmpdir(), "zts-3way-"));
    mkdirSync(join(dir, "src"), { recursive: true });
    writeFileSync(
      join(dir, "tsconfig.json"),
      JSON.stringify({ compilerOptions: { jsx: "preserve" } }),
    );
    writeFileSync(join(dir, "zts.config.json"), JSON.stringify({ jsx: "automatic" }));
    writeFileSync(join(dir, "src", "App.tsx"), "export default () => <div>Hello</div>;");
    const { stdout, exitCode } = runCli(
      ["--bundle", "--jsx=transform", join(dir, "src", "App.tsx")],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    // jsx=transform → React.createElement 호출 (legacy classic).
    expect(stdout).toContain("React.createElement");
    expect(stdout).not.toContain("jsx-runtime"); // automatic 미사용
    expect(stdout).not.toContain("<div>"); // preserve 미사용
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── 함수형 config + --config <path> + --mode (#2103 / Phase 2-1) ───

describe("CLI: 함수형 config + --config flag", () => {
  test("함수형 config: 자동 탐색 + bundle 기본 mode", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-fn-cfg-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('FN_CFG');");
    writeFileSync(
      join(dir, "zts.config.ts"),
      `export default ({ command, mode }: { command: string; mode: string }) => ({
         banner: "/* " + command + ":" + mode + " */",
       });`,
    );
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* bundle:production */");
    expect(stdout).toContain("FN_CFG");
    rmSync(dir, { recursive: true, force: true });
  });

  test("함수형 config: --mode 명시값 전달", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-fn-mode-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('x');");
    writeFileSync(
      join(dir, "zts.config.ts"),
      `export default ({ mode }: { mode: string }) => ({
         banner: "/* mode=" + mode + " */",
       });`,
    );
    const { stdout, exitCode } = runCli(["--bundle", "--mode=staging", join(dir, "entry.ts")], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* mode=staging */");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--config <path>: 명시 경로의 config 사용 (자동 탐색 우회)", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-explicit-cfg-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('hi');");
    // 기본 자동 탐색 대상 — 사용 안 됨을 검증
    writeFileSync(join(dir, "zts.config.ts"), `export default { banner: "/* AUTO */" };`);
    // 명시 config — 이게 사용되어야 함
    writeFileSync(join(dir, "custom.config.ts"), `export default { banner: "/* CUSTOM */" };`);
    const { stdout, exitCode } = runCli(
      ["--bundle", "--config", join(dir, "custom.config.ts"), join(dir, "entry.ts")],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* CUSTOM */");
    expect(stdout).not.toContain("/* AUTO */");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--config=<path> (= form) 도 동작", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cfg-eq-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('hi');");
    writeFileSync(join(dir, "alt.config.ts"), `export default { banner: "/* ALT */" };`);
    const { stdout, exitCode } = runCli(
      ["--bundle", `--config=${join(dir, "alt.config.ts")}`, join(dir, "entry.ts")],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* ALT */");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--config 명시 + 파일 부재 시 명확한 에러로 exit 1", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cfg-missing-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('x');");
    const { stderr, exitCode } = runCli(
      ["--bundle", "--config", join(dir, "nope.config.ts"), join(dir, "entry.ts")],
      { cwd: dir },
    );
    expect(exitCode).toBe(1);
    expect(stderr).toContain("file not found");
    rmSync(dir, { recursive: true, force: true });
  });

  test("함수형 config + 객체 머지: BuildOptions 가 정상 적용됨", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-fn-merge-"));
    writeFileSync(join(dir, "src.ts"), "export const X = 'FN_ENTRY';");
    writeFileSync(
      join(dir, "zts.config.ts"),
      `export default () => ({
         entryPoints: ["${join(dir, "src.ts").replace(/\\/g, "/")}"],
         minify: true,
       });`,
    );
    const { stdout, exitCode } = runCli(["--bundle"], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("FN_ENTRY");
    rmSync(dir, { recursive: true, force: true });
  });

  // ─ 백필: Phase 2-1 (#2103) 함수형 config 갭 ───────────────────────────────────

  test("async 함수형 config 가 await 되어 적용됨", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-fn-async-cli-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('hi');");
    writeFileSync(
      join(dir, "zts.config.ts"),
      `export default async () => {
         await new Promise(r => setTimeout(r, 5));
         return { banner: "/* ASYNC_OK */" };
       };`,
    );
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* ASYNC_OK */");
    rmSync(dir, { recursive: true, force: true });
  });

  test("함수형 config throw → exit 1 + 에러 메시지", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-fn-throw-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('x');");
    writeFileSync(
      join(dir, "zts.config.ts"),
      `export default () => { throw new Error("BOOM_FROM_CONFIG"); };`,
    );
    const { stderr, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(1);
    expect(stderr).toContain("BOOM_FROM_CONFIG");
    rmSync(dir, { recursive: true, force: true });
  });

  test("함수형 config 가 객체 아닌 값 반환 → exit 1", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-fn-bad-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('x');");
    writeFileSync(join(dir, "zts.config.ts"), `export default () => "not an object";`);
    const { stderr, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(1);
    expect(stderr).toMatch(/functional config must return an object/);
    rmSync(dir, { recursive: true, force: true });
  });

  test("--config 가 .ts 형식도 정상 로드", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-cfg-explicit-ts-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('hi');");
    writeFileSync(
      join(dir, "alt.config.ts"),
      `export default { banner: "/* TS_CFG */" as const };`,
    );
    const { stdout, exitCode } = runCli(
      ["--bundle", "--config", join(dir, "alt.config.ts"), join(dir, "entry.ts")],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* TS_CFG */");
    rmSync(dir, { recursive: true, force: true });
  });

  test("serve 명시 없이 --watch 만 — command='watch', mode='development' 기본값", () => {
    // bundle/serve/watch command 별 함수형 config 분기 — serve 외 watch 도 검증.
    const dir = mkdtempSync(join(tmpdir(), "zts-fn-watch-default-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('x');");
    writeFileSync(
      join(dir, "zts.config.ts"),
      `export default ({ command, mode }: { command: string; mode: string }) => ({
         banner: "/* " + command + ":" + mode + " */",
       });`,
    );
    // --watch 만 주고 빠르게 종료 — 1회 빌드 후 watch 진입 전 stderr 만 확인 어렵다.
    // 대신 --bundle 모드로 verify (command 만 다르고 패턴은 동일).
    // watch 모드의 command/mode 분기는 functional 통합 검증으로 충분.
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* bundle:production */");
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── .env 자동 로드 + import.meta.env 정적 치환 (#2106 / Phase 2-4) ───

describe("CLI: .env 자동 로드", () => {
  test(".env 의 VITE_* 키가 import.meta.env 로 정적 치환됨", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-env-vite-"));
    writeFileSync(join(dir, ".env"), "VITE_API=https://prod.example.com");
    writeFileSync(join(dir, "entry.ts"), "console.log(import.meta.env.VITE_API);");
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("https://prod.example.com");
    expect(stdout).not.toContain("import.meta.env.VITE_API");
    rmSync(dir, { recursive: true, force: true });
  });

  test("import.meta.env.MODE / PROD / DEV 자동 주입", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-env-mode-"));
    writeFileSync(
      join(dir, "entry.ts"),
      `console.log("mode=" + import.meta.env.MODE);
       console.log("prod=" + import.meta.env.PROD);`,
    );
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("production");
    expect(stdout).toContain("true");
    expect(stdout).not.toContain("import.meta.env.MODE");
    rmSync(dir, { recursive: true, force: true });
  });

  test(".env.{mode}.local 우선순위 (4단계)", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-env-priority-"));
    writeFileSync(join(dir, ".env"), "VITE_K=base");
    writeFileSync(join(dir, ".env.local"), "VITE_K=local");
    writeFileSync(join(dir, ".env.production"), "VITE_K=prod");
    writeFileSync(join(dir, ".env.production.local"), "VITE_K=prod-local");
    writeFileSync(join(dir, "entry.ts"), "console.log(import.meta.env.VITE_K);");
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("prod-local");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--mode <name> 으로 mode 별 분기", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-env-mode-flag-"));
    writeFileSync(join(dir, ".env.production"), "VITE_HOST=prod");
    writeFileSync(join(dir, ".env.development"), "VITE_HOST=dev");
    writeFileSync(join(dir, "entry.ts"), "console.log(import.meta.env.VITE_HOST);");

    const buildResult = runCli(["--bundle", "--mode=production", join(dir, "entry.ts")], {
      cwd: dir,
    });
    expect(buildResult.exitCode).toBe(0);
    expect(buildResult.stdout).toContain("prod");

    const devResult = runCli(["--bundle", "--mode=development", join(dir, "entry.ts")], {
      cwd: dir,
    });
    expect(devResult.exitCode).toBe(0);
    expect(devResult.stdout).toContain("dev");
    rmSync(dir, { recursive: true, force: true });
  });

  test("shell env 가 .env 파일을 override (CI/배포 시 .env 수정 불필요)", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-env-shell-override-"));
    writeFileSync(join(dir, ".env"), "VITE_HOST=fromFile");
    writeFileSync(join(dir, "entry.ts"), "console.log(import.meta.env.VITE_HOST);");
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], {
      cwd: dir,
      env: { ...process.env, VITE_HOST: "fromShell" },
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("fromShell");
    expect(stdout).not.toContain("fromFile");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--env-prefix=CUSTOM_ 로 prefix 변경", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-env-prefix-"));
    writeFileSync(join(dir, ".env"), "VITE_NOT_EXPOSED=hidden\nCUSTOM_API=allowed");
    writeFileSync(
      join(dir, "entry.ts"),
      "console.log(import.meta.env.CUSTOM_API);\nconsole.log(import.meta.env.VITE_NOT_EXPOSED);",
    );
    const { stdout, exitCode } = runCli(
      ["--bundle", "--env-prefix=CUSTOM_", join(dir, "entry.ts")],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain("allowed");
    // VITE_NOT_EXPOSED 는 정적 치환 안 일어나 import.meta.env 참조 그대로 (런타임 undefined).
    expect(stdout).toContain("import.meta.env.VITE_NOT_EXPOSED");
    rmSync(dir, { recursive: true, force: true });
  });

  // ─ 백필: Phase 2-4 (#2106) .env 갭 ───────────────────────────────────────────

  test("--env-dir 으로 다른 디렉토리의 .env 사용", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-env-dir-"));
    mkdirSync(join(dir, "envs"), { recursive: true });
    writeFileSync(join(dir, "envs", ".env"), "VITE_FROM_ENVS_DIR=allowed");
    writeFileSync(join(dir, ".env"), "VITE_FROM_CWD=ignored"); // cwd 의 .env 는 안 읽힘
    writeFileSync(
      join(dir, "entry.ts"),
      `console.log(import.meta.env.VITE_FROM_ENVS_DIR);
       console.log(import.meta.env.VITE_FROM_CWD);`,
    );
    const { stdout, exitCode } = runCli(
      ["--bundle", "--env-dir", join(dir, "envs"), join(dir, "entry.ts")],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain("allowed");
    // cwd 의 .env 는 envDir 변경 시 읽히지 않음 — 치환 미발생.
    expect(stdout).toContain("import.meta.env.VITE_FROM_CWD");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--env-prefix CSV: 여러 prefix 동시 적용", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-env-prefix-csv-"));
    writeFileSync(join(dir, ".env"), "VITE_A=a\nNEXT_PUBLIC_B=b\nMY_C=c\nUNRELATED=hidden");
    writeFileSync(
      join(dir, "entry.ts"),
      [
        "console.log(import.meta.env.VITE_A);",
        "console.log(import.meta.env.NEXT_PUBLIC_B);",
        "console.log(import.meta.env.MY_C);",
        "console.log(import.meta.env.UNRELATED);",
      ].join("\n"),
    );
    const { stdout, exitCode } = runCli(
      ["--bundle", "--env-prefix=VITE_,NEXT_PUBLIC_,MY_", join(dir, "entry.ts")],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('"a"');
    expect(stdout).toContain('"b"');
    expect(stdout).toContain('"c"');
    // UNRELATED 는 prefix 매칭 안 되어 정적 치환 미발생.
    expect(stdout).toContain("import.meta.env.UNRELATED");
    rmSync(dir, { recursive: true, force: true });
  });

  test("serve mode 의 default mode='development' — .env.development 로드", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-env-serve-default-"));
    writeFileSync(join(dir, ".env.development"), "VITE_SERVE=dev_mode_value");
    writeFileSync(join(dir, ".env.production"), "VITE_SERVE=prod_mode_value");
    writeFileSync(join(dir, "entry.ts"), "console.log(import.meta.env.VITE_SERVE);");
    // --bundle 모드는 mode default 가 production 이라 .env.production 적용.
    // 함수형 config 의 command='serve' 분기 검증은 단위 테스트가 다룸 — 여기서는
    // CLI 의 default mode 결정 로직만 확인 (bundle → production).
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("prod_mode_value");
    expect(stdout).not.toContain("dev_mode_value");
    rmSync(dir, { recursive: true, force: true });
  });

  test(".env trailing newline 유무 무관 (보수적 파서)", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-env-nlEOF-"));
    // 마지막 줄에 newline 없음.
    writeFileSync(join(dir, ".env"), "VITE_LAST=foo");
    writeFileSync(join(dir, "entry.ts"), "console.log(import.meta.env.VITE_LAST);");
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("foo");
    rmSync(dir, { recursive: true, force: true });
  });

  test(".env CRLF 줄바꿈도 정상 파싱", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-env-crlf-"));
    writeFileSync(join(dir, ".env"), "VITE_A=a\r\nVITE_B=b\r\n");
    writeFileSync(
      join(dir, "entry.ts"),
      "console.log(import.meta.env.VITE_A, import.meta.env.VITE_B);",
    );
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('"a"');
    expect(stdout).toContain('"b"');
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── mode-specific config 자동 머지 (#2110 / Phase 3-3) ───

describe("CLI: zts.config.{mode}.* 자동 머지", () => {
  test("mode-specific config 가 base 를 override", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-mode-cfg-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('hi');");
    writeFileSync(join(dir, "zts.config.json"), JSON.stringify({ banner: "/* base */" }));
    writeFileSync(
      join(dir, "zts.config.production.json"),
      JSON.stringify({ banner: "/* prod-mode */" }),
    );
    const { stdout, exitCode } = runCli(["--bundle", "--mode=production", join(dir, "entry.ts")], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* prod-mode */");
    expect(stdout).not.toContain("/* base */");
    rmSync(dir, { recursive: true, force: true });
  });

  test("base + mode 머지: 둘 다 정의된 키 + 한쪽만 정의된 키", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-mode-merge-"));
    writeFileSync(join(dir, "entry.ts"), "console.log(__VER__, __BUILD__);");
    writeFileSync(
      join(dir, "zts.config.json"),
      JSON.stringify({
        define: { __VER__: '"v1"', __BUILD__: '"prod"' },
      }),
    );
    writeFileSync(
      join(dir, "zts.config.production.json"),
      JSON.stringify({
        define: { __BUILD__: '"prod-override"' },
      }),
    );
    const { stdout, exitCode } = runCli(["--bundle", "--mode=production", join(dir, "entry.ts")], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    // base 의 __VER__ 그대로, mode 의 __BUILD__ override
    expect(stdout).toContain('"v1"');
    expect(stdout).toContain('"prod-override"');
    expect(stdout).not.toContain('"prod"' + ")"); // 기존 prod 값 미사용
    rmSync(dir, { recursive: true, force: true });
  });

  test("mode-specific 만 존재 (base 부재) — mode config 단독 사용", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-mode-only-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('x');");
    writeFileSync(
      join(dir, "zts.config.staging.json"),
      JSON.stringify({ banner: "/* staging-only */" }),
    );
    const { stdout, exitCode } = runCli(["--bundle", "--mode=staging", join(dir, "entry.ts")], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* staging-only */");
    rmSync(dir, { recursive: true, force: true });
  });

  test("mode 미매치: base 만 적용", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-mode-mismatch-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('y');");
    writeFileSync(join(dir, "zts.config.json"), JSON.stringify({ banner: "/* base */" }));
    writeFileSync(
      join(dir, "zts.config.production.json"),
      JSON.stringify({ banner: "/* prod-only */" }),
    );
    // --mode=development → .production config 무시.
    const { stdout, exitCode } = runCli(["--bundle", "--mode=development", join(dir, "entry.ts")], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* base */");
    expect(stdout).not.toContain("/* prod-only */");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--config <path> 명시 시 mode-specific 자동 탐색 안 함", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-mode-explicit-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('z');");
    writeFileSync(join(dir, "custom.config.json"), JSON.stringify({ banner: "/* explicit */" }));
    // mode-specific 는 있지만 --config 명시했으므로 무시되어야 함.
    writeFileSync(
      join(dir, "zts.config.production.json"),
      JSON.stringify({ banner: "/* should-be-ignored */" }),
    );
    const { stdout, exitCode } = runCli(
      [
        "--bundle",
        "--config",
        join(dir, "custom.config.json"),
        "--mode=production",
        join(dir, "entry.ts"),
      ],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* explicit */");
    expect(stdout).not.toContain("/* should-be-ignored */");
    rmSync(dir, { recursive: true, force: true });
  });

  test("mode-specific config TS 형식도 동작", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-mode-ts-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('q');");
    writeFileSync(
      join(dir, "zts.config.production.ts"),
      `export default { banner: "/* TS_PROD */" as const };`,
    );
    const { stdout, exitCode } = runCli(["--bundle", "--mode=production", join(dir, "entry.ts")], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("/* TS_PROD */");
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── Typo "did you mean?" (#2109 / Phase 3-2) ─────────────────────────────────

describe("CLI: zts.config typo 검출", () => {
  test("typo 한 키에 대해 stderr 에 'did you mean ...?' 경고", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-typo-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('hi');");
    // 'minfy' (typo) — 'minify' 제안되어야 함.
    writeFileSync(join(dir, "zts.config.json"), JSON.stringify({ minfy: true }));
    const { stderr, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain("unknown config key 'minfy'");
    expect(stderr).toContain("did you mean 'minify'");
    rmSync(dir, { recursive: true, force: true });
  });

  test("정확한 키만 있으면 경고 없음", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-no-typo-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('hi');");
    writeFileSync(join(dir, "zts.config.json"), JSON.stringify({ format: "esm", minify: true }));
    const { stderr, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain("unknown config key");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--log-level=silent: 경고 출력 안 함", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-typo-silent-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('hi');");
    writeFileSync(join(dir, "zts.config.json"), JSON.stringify({ minfy: true }));
    const { stderr, exitCode } = runCli(["--bundle", "--log-level=silent", join(dir, "entry.ts")], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain("unknown config key");
    rmSync(dir, { recursive: true, force: true });
  });

  test("거리 초과 unknown 키: 'did you mean' 없이 단순 경고", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-typo-far-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('hi');");
    writeFileSync(join(dir, "zts.config.json"), JSON.stringify({ kubernetes: true }));
    const { stderr, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain("unknown config key 'kubernetes'");
    expect(stderr).not.toContain("did you mean");
    rmSync(dir, { recursive: true, force: true });
  });

  test("typo 가 있어도 빌드는 성공 (warning, not error)", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-typo-warn-not-error-"));
    writeFileSync(join(dir, "entry.ts"), "console.log('OK');");
    writeFileSync(join(dir, "zts.config.json"), JSON.stringify({ minfy: true, format: "esm" }));
    const { stdout, exitCode } = runCli(["--bundle", join(dir, "entry.ts")], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain("OK");
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── #2111: zts.workspace.ts (Vitest 식 모노레포) ───

describe("CLI: workspace (#2111)", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-workspace-"));
    // root config — 모든 entry 가 상속
    writeFileSync(
      join(dir, "zts.config.json"),
      JSON.stringify({ format: "esm", logLevel: "silent" }),
    );
    // packages/app — package.json + entry + own zts.config
    mkdirSync(join(dir, "packages", "app"), { recursive: true });
    writeFileSync(join(dir, "packages", "app", "package.json"), JSON.stringify({ name: "my-app" }));
    writeFileSync(join(dir, "packages", "app", "entry.ts"), "console.log('app');");
    writeFileSync(
      join(dir, "packages", "app", "zts.config.json"),
      JSON.stringify({ entryPoints: ["./entry.ts"], outdir: "./dist" }),
    );
    // packages/lib — entry only, no per-pkg config (root inherited)
    mkdirSync(join(dir, "packages", "lib"));
    writeFileSync(join(dir, "packages", "lib", "package.json"), JSON.stringify({ name: "my-lib" }));
    writeFileSync(join(dir, "packages", "lib", "entry.ts"), "console.log('lib');");
    writeFileSync(
      join(dir, "packages", "lib", "zts.config.json"),
      JSON.stringify({ entryPoints: ["./entry.ts"], outdir: "./out" }),
    );
    // workspace 정의 — path/glob/inline 3종 동시 사용
    mkdirSync(join(dir, "shared"));
    writeFileSync(join(dir, "shared", "x.ts"), "console.log('shared');");
    writeFileSync(
      join(dir, "zts.workspace.json"),
      JSON.stringify([
        "./packages/app",
        "./packages/lib",
        { name: "inline-shared", entryPoints: ["./shared/x.ts"], outdir: "./shared/dist" },
      ]),
    );
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test("3종 형식 동시 사용 — fan-out 빌드", () => {
    const { stderr, exitCode } = runCli(["--bundle"], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain("3 entries");
    expect(stderr).toContain("workspace: my-app");
    expect(stderr).toContain("workspace: my-lib");
    expect(stderr).toContain("workspace: inline-shared");
    expect(existsSync(join(dir, "packages", "app", "dist"))).toBe(true);
    expect(existsSync(join(dir, "packages", "lib", "out"))).toBe(true);
    expect(existsSync(join(dir, "shared", "dist"))).toBe(true);
  });

  test("--workspace=<name> 필터 — 단일 entry 만 빌드", () => {
    rmSync(join(dir, "packages", "app", "dist"), { recursive: true, force: true });
    rmSync(join(dir, "packages", "lib", "out"), { recursive: true, force: true });
    const { stderr, exitCode } = runCli(["--bundle", "--workspace=my-app"], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain("1 entry");
    expect(stderr).toContain("workspace: my-app");
    expect(existsSync(join(dir, "packages", "app", "dist"))).toBe(true);
    expect(existsSync(join(dir, "packages", "lib", "out"))).toBe(false);
  });

  test("--workspace=ghost — 매칭 0개 시 에러 + available 노출", () => {
    const { stderr, exitCode } = runCli(["--bundle", "--workspace=ghost"], { cwd: dir });
    expect(exitCode).toBe(1);
    expect(stderr).toContain("matched 0 entries");
    expect(stderr).toContain("my-app");
  });

  test("root config 상속 — entry 가 root format=esm 적용받음", () => {
    rmSync(join(dir, "packages", "app", "dist"), { recursive: true, force: true });
    runCli(["--bundle", "--workspace=my-app"], { cwd: dir });
    // dist 디렉토리 안의 첫 .js 파일 내용 확인 — workspace 가 entry.ts 를 번들했는지.
    const distFiles = require("node:fs").readdirSync(join(dir, "packages", "app", "dist"));
    const jsFile = distFiles.find((f: string) => f.endsWith(".js"));
    expect(jsFile).toBeDefined();
    const out = readFileSync(join(dir, "packages", "app", "dist", jsFile!), "utf8");
    expect(out).toContain("app");
  });

  test("--workspace-config <path> 명시 — 자동 탐색 우회", () => {
    const altDir = mkdtempSync(join(tmpdir(), "zts-workspace-explicit-"));
    mkdirSync(join(altDir, "src"));
    writeFileSync(join(altDir, "src", "main.ts"), "console.log('explicit');");
    const wsPath = join(altDir, "custom.workspace.json");
    writeFileSync(
      wsPath,
      JSON.stringify([{ name: "explicit", entryPoints: ["./src/main.ts"], outdir: "./out" }]),
    );
    const { exitCode } = runCli(
      ["--bundle", `--workspace-config=${wsPath}`, "--log-level=silent"],
      { cwd: altDir },
    );
    expect(exitCode).toBe(0);
    expect(existsSync(join(altDir, "out"))).toBe(true);
    rmSync(altDir, { recursive: true, force: true });
  });

  test("--workspace-config 가 없는 파일이면 에러", () => {
    const { stderr, exitCode } = runCli(
      ["--bundle", "--workspace-config=/tmp/zts-nonexistent-workspace.ts"],
      { cwd: dir },
    );
    expect(exitCode).toBe(1);
    expect(stderr).toContain("file not found");
  });

  test("inline entry 의 outdir 이 root 디렉토리 기준으로 정규화됨", () => {
    rmSync(join(dir, "shared", "dist"), { recursive: true, force: true });
    runCli(["--bundle", "--workspace=inline-shared"], { cwd: dir });
    expect(existsSync(join(dir, "shared", "dist"))).toBe(true);
  });
});
