import { describe, test, expect, afterEach } from "bun:test";
import { join, resolve } from "node:path";
import { createFixture, runZtsInDir } from "./helpers";
import { spawn } from "bun";

const CORE_PATH = resolve(import.meta.dir, "../../../packages/plugin/index.ts");

describe("config 옵션 확장", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("config.define이 BundleOptions에 적용됨", async () => {
    const { dir, cleanup: c } = await createFixture({
      "entry.ts": `console.log(MY_VERSION);`,
      "package.json": '{"type": "module"}',
      "zts.config.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({
          define: { 'MY_VERSION': '"1.0.0"' }
        });
      `,
    });
    cleanup = c;

    const result = await runZtsInDir(dir, ["--bundle", "entry.ts"]);
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain('"1.0.0"');
    expect(result.stdout).not.toContain("MY_VERSION");
  });

  test("config.alias가 BundleOptions에 적용됨", async () => {
    const { dir, cleanup: c } = await createFixture({
      "entry.ts": `import { hello } from '@utils/greet';\nconsole.log(hello());`,
      "src/greet.ts": `export function hello() { return "hi"; }`,
      "package.json": '{"type": "module"}',
      "zts.config.js": `
        import { defineConfig } from '${CORE_PATH}';
        import { resolve } from 'node:path';
        defineConfig({
          alias: { '@utils': resolve(import.meta.dir, 'src') }
        });
      `,
    });
    cleanup = c;

    const result = await runZtsInDir(dir, ["--bundle", "entry.ts"]);
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("hi");
  });

  test("config.external이 적용됨", async () => {
    const { dir, cleanup: c } = await createFixture({
      "entry.ts": `import React from 'react';\nconsole.log(React);`,
      "package.json": '{"type": "module"}',
      "zts.config.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({
          external: ['react']
        });
      `,
    });
    cleanup = c;

    const result = await runZtsInDir(dir, ["--bundle", "entry.ts", "--platform=node"]);
    expect(result.exitCode).toBe(0);
    // external이면 require 구문이 유지됨
    expect(result.stdout).toContain('require("react")');
  });

  test("config.minify가 적용됨", async () => {
    const { dir, cleanup: c } = await createFixture({
      "entry.ts": `const x = 42;\nconsole.log(x);`,
      "package.json": '{"type": "module"}',
      "zts.config.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({ minify: true });
      `,
    });
    cleanup = c;

    const result = await runZtsInDir(dir, ["--bundle", "entry.ts"]);
    expect(result.exitCode).toBe(0);
    // minify_whitespace가 적용되면 줄바꿈이 최소화됨
    const lines = result.stdout.trim().split("\n");
    // 비 minify면 여러 줄, minify면 줄 수가 적음
    expect(lines.length).toBeLessThanOrEqual(2);
  });

  test("config.banner/footer가 적용됨", async () => {
    const { dir, cleanup: c } = await createFixture({
      "entry.ts": `console.log("hello");`,
      "package.json": '{"type": "module"}',
      "zts.config.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({
          banner: { js: '/* BANNER */' },
          footer: { js: '/* FOOTER */' }
        });
      `,
    });
    cleanup = c;

    const result = await runZtsInDir(dir, ["--bundle", "entry.ts"]);
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("/* BANNER */");
    expect(result.stdout).toContain("/* FOOTER */");
  });

  test("CLI 옵션이 config보다 우선", async () => {
    const { dir, cleanup: c } = await createFixture({
      "entry.ts": `console.log(MY_VAR);`,
      "package.json": '{"type": "module"}',
      "zts.config.js": `
        import { defineConfig } from '${CORE_PATH}';
        defineConfig({
          define: { 'MY_VAR': '"from-config"' }
        });
      `,
    });
    cleanup = c;

    // CLI에서 define 지정 → config 무시
    const result = await runZtsInDir(dir, ["--bundle", "entry.ts", '--define:MY_VAR="from-cli"']);
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("from-cli");
    expect(result.stdout).not.toContain("from-config");
  });
});

describe("build() API", () => {
  test("build()로 번들 생성", async () => {
    const { dir, cleanup } = await createFixture({
      "src/index.ts": `export const hello = "world";`,
      "build.ts": `
        import { build } from '${CORE_PATH}';
        const result = await build({
          entryPoints: ['src/index.ts'],
          bundle: true,
        });
        if (result.errors.length > 0) {
          console.error(result.errors.join('\\n'));
          process.exit(1);
        }
        // stdout에 출력 파일 내용을 출력
        for (const f of result.outputFiles) {
          console.log(f.contents);
        }
      `,
      "package.json": '{"type": "module"}',
    });

    try {
      const proc = spawn({
        cmd: ["bun", "run", join(dir, "build.ts")],
        stdout: "pipe",
        stderr: "pipe",
        cwd: dir,
        env: { ...process.env, ZTS_BIN: resolve(import.meta.dir, "../../../zig-out/bin/zts") },
      });
      const stdout = await new Response(proc.stdout).text();
      const exitCode = await proc.exited;

      expect(exitCode).toBe(0);
      expect(stdout).toContain("world");
    } finally {
      await cleanup();
    }
  });

  test("build() outfile로 단일 파일 출력", async () => {
    const { dir, cleanup } = await createFixture({
      "src/index.ts": `export const hello = "from-build-api";`,
      "build.ts": `
        import { build } from '${CORE_PATH}';
        const result = await build({
          entryPoints: [process.cwd() + '/src/index.ts'],
          outfile: process.cwd() + '/out.js',
          bundle: true,
        });
        if (result.errors.length > 0) {
          console.error(result.errors.join('\\n'));
          process.exit(1);
        }
        console.log(JSON.stringify({ count: result.outputFiles.length, hasContent: result.outputFiles[0]?.contents.includes('from-build-api') }));
      `,
      "package.json": '{"type": "module"}',
    });

    try {
      const proc = spawn({
        cmd: ["bun", "run", join(dir, "build.ts")],
        stdout: "pipe",
        stderr: "pipe",
        cwd: dir,
        env: { ...process.env, ZTS_BIN: resolve(import.meta.dir, "../../../zig-out/bin/zts") },
      });
      const stdout = await new Response(proc.stdout).text();
      const exitCode = await proc.exited;

      expect(exitCode).toBe(0);
      const parsed = JSON.parse(stdout.trim());
      expect(parsed.count).toBe(1);
      expect(parsed.hasContent).toBe(true);
    } finally {
      await cleanup();
    }
  });

  test("build() 에러 시 errors 배열 반환", async () => {
    const { dir, cleanup } = await createFixture({
      "build.ts": `
        import { build } from '${CORE_PATH}';
        const result = await build({
          entryPoints: ['/absolutely/nonexistent/path.ts'],
          bundle: true,
        });
        console.log(JSON.stringify({ hasErrors: result.errors.length > 0 }));
      `,
      "package.json": '{"type": "module"}',
    });

    try {
      const proc = spawn({
        cmd: ["bun", "run", join(dir, "build.ts")],
        stdout: "pipe",
        stderr: "pipe",
        cwd: dir,
        env: { ...process.env, ZTS_BIN: resolve(import.meta.dir, "../../../zig-out/bin/zts") },
      });
      const stdout = await new Response(proc.stdout).text();
      const exitCode = await proc.exited;

      expect(exitCode).toBe(0);
      const parsed = JSON.parse(stdout.trim());
      expect(parsed.hasErrors).toBe(true);
    } finally {
      await cleanup();
    }
  });
});
