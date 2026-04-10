/**
 * ZTS Node.js CLI 테스트
 *
 * CLI를 subprocess로 실행하여 실제 동작을 검증.
 * bun test packages/core/bin/zts.test.ts
 */

import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const CLI = resolve(import.meta.dir, "zts.mjs");
const RUNTIME = "bun";

async function waitForServer(port: number, maxRetries = 20, interval = 100) {
  for (let i = 0; i < maxRetries; i++) {
    try {
      await fetch(`http://localhost:${port}/`);
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
