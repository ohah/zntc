/**
 * ZTS Node.js CLI 테스트
 *
 * CLI를 subprocess로 실행하여 실제 동작을 검증.
 * bun test packages/core/bin/zts.test.ts
 */

import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { spawn, spawnSync, execSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const CLI = resolve(import.meta.dir, "zts.mjs");
const RUNTIME = "bun";

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

function runCli(args: string[], options: { input?: string; cwd?: string; timeout?: number } = {}) {
  const result = spawnSync(RUNTIME, [CLI, ...args], {
    input: options.input,
    cwd: options.cwd,
    stdio: ["pipe", "pipe", "pipe"],
    timeout: options.timeout ?? 10000,
  });
  return {
    stdout: result.stdout?.toString() ?? "",
    stderr: result.stderr?.toString() ?? "",
    exitCode: result.status ?? 1,
  };
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
    const run = spawnSync("node", ["-e", `const m = require("${outFile}"); console.log(m.msg);`], {
      cwd: mockDir,
    });
    expect(run.stdout?.toString().trim()).toBe("Hello world");

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
    const run = spawnSync(
      "node",
      [
        "-e",
        `const m = require("${outFile}"); console.log(m.version); const el = m.Greeting({ name: "ZTS" }); console.log(el.type + ":" + el.props.children);`,
      ],
      {
        cwd: projectRoot,
        env: { ...process.env, NODE_PATH: join(projectRoot, "node_modules") },
      },
    );
    const lines = (run.stdout?.toString().trim() ?? "").split("\n");
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

    const proc = spawn(RUNTIME, [
      CLI,
      "--bundle",
      join(dir, "index.ts"),
      "--outdir",
      outDir,
      "--watch-json",
    ]);

    const lines: string[] = [];
    const linePromise = new Promise<void>((resolve) => {
      proc.stdout.on("data", (data) => {
        for (const line of data.toString().split("\n").filter(Boolean)) {
          lines.push(line);
          // ready 이벤트를 받으면 종료
          try {
            const event = JSON.parse(line);
            if (event.type === "ready" || event.type === "rebuild") {
              resolve();
            }
          } catch {}
        }
      });
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
});

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
