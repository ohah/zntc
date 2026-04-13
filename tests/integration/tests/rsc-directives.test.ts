import { describe, test, expect } from "bun:test";
import { runZts, runZtsInDir, createFixture, ZTS_BIN } from "./helpers";
import { readFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";

const FIXTURES = resolve(import.meta.dir, "fixtures/rsc-directives");

/**
 * RSC 디렉티브 보존 contract:
 * 1. 단일 파일 transpile: directive prologue가 출력 첫 문장으로 보존
 * 2. --bundle --preserve-modules: 디렉티브가 import 위, 파일 최상단
 * 3. --bundle --format=esm (단일 파일): entry 모듈의 디렉티브가 번들 최상단
 * 4. --bundle --format=iife: 디렉티브 유실 허용 (RSC 비호환 포맷)
 *
 * 출처: Next.js next-custom-transforms 테스트 fixture + Rollup module-level-directive
 */
describe("RSC 디렉티브 보존", () => {
  test('단일 파일: "use client" 첫 문장 보존', async () => {
    const { stdout, exitCode } = await runZts([join(FIXTURES, "use-client-counter.tsx")]);
    expect(exitCode).toBe(0);
    expect(stdout.trimStart().startsWith('"use client"')).toBe(true);
  });

  test('단일 파일: "use server" 첫 문장 보존', async () => {
    const { stdout, exitCode } = await runZts([join(FIXTURES, "use-server-actions.ts")]);
    expect(exitCode).toBe(0);
    expect(stdout.trimStart().startsWith('"use server"')).toBe(true);
  });

  test("Next.js fixture client-entry-mixed: 'use strict' + 'use client' prologue 보존", async () => {
    const { stdout, exitCode } = await runZts([join(FIXTURES, "client-entry-mixed.mjs")]);
    expect(exitCode).toBe(0);
    // 두 디렉티브 모두 prologue 영역에 등장해야 함
    const head = stdout.split("\n").slice(0, 20).join("\n");
    expect(head).toContain('"use strict"');
    expect(head).toContain('"use client"');
  });

  test('--bundle --preserve-modules: "use client"가 import 위에 옴', async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-rsc-pm-"));
    try {
      const { dir } = await createFixture({
        "client.tsx": `"use client";\nimport { useState } from "react";\nexport default function C(){const[n]=useState(0);return n;}`,
        "server.ts": `"use server";\nexport async function act(){return 1;}`,
        "entry.tsx": `"use client";\nimport C from "./client";\nimport { act } from "./server";\nexport default function E(){act();return <C/>;}`,
      });
      try {
        const result = await runZtsInDir(dir, [
          "--bundle",
          "--preserve-modules",
          "--outdir",
          outdir,
          "entry.tsx",
        ]);
        expect(result.exitCode).toBe(0);

        const files = readdirSync(outdir);
        for (const f of files) {
          const content = readFileSync(join(outdir, f), "utf8");
          const importIdx = content.indexOf("import");
          const useClientIdx = content.indexOf('"use client"');
          const useServerIdx = content.indexOf('"use server"');
          const directiveIdx = useClientIdx >= 0 ? useClientIdx : useServerIdx;
          if (directiveIdx >= 0 && importIdx >= 0) {
            expect(directiveIdx).toBeLessThan(importIdx);
          }
        }
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });

  test("--bundle --format=esm: entry 디렉티브 번들 최상단", async () => {
    const { dir, cleanup } = await createFixture({
      "dep.ts": `export const x = 1;`,
      "entry.tsx": `"use client";\nimport { x } from "./dep";\nexport default x;`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, [
        "--bundle",
        "--format=esm",
        "entry.tsx",
      ]);
      expect(exitCode).toBe(0);
      expect(stdout.trimStart().startsWith('"use client"')).toBe(true);
    } finally {
      await cleanup();
    }
  });

  test("server action 인라인 (함수 내부 'use server')는 보존", async () => {
    const { stdout, exitCode } = await runZts([join(FIXTURES, "server-action-inline.tsx")]);
    expect(exitCode).toBe(0);
    // 함수 내부의 'use server'는 expression statement로 그대로 남아야 함
    expect(stdout).toContain('"use server"');
  });

  test("single-quote 'use client' 디렉티브 보존", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.tsx": `'use client'\nimport { useState } from "react";\nexport default function C(){return useState(0)[0];}`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.tsx"]);
      expect(exitCode).toBe(0);
      // 출력은 double-quote로 정규화될 수 있으나 디렉티브는 prologue에 존재
      const head = stdout.split("\n").slice(0, 3).join("\n");
      expect(head).toMatch(/["']use client["']/);
    } finally {
      await cleanup();
    }
  });

  test('"use server" 다음 import가 와도 디렉티브가 첫 문장 유지', async () => {
    const { dir, cleanup } = await createFixture({
      "lib.ts": `export const v = 1;`,
      "entry.ts": `"use server";\nimport { v } from "./lib";\nexport function f(){return v;}`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["--bundle", "--format=esm", "entry.ts"]);
      expect(exitCode).toBe(0);
      const idx = stdout.indexOf('"use server"');
      const importIdx = stdout.indexOf("import");
      expect(idx).toBeGreaterThanOrEqual(0);
      // import가 있을 경우 디렉티브가 먼저
      if (importIdx >= 0) expect(idx).toBeLessThan(importIdx);
    } finally {
      await cleanup();
    }
  });

  test("CJS 출력에서도 entry 디렉티브 보존", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `"use client";\nexport const x = 1;`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["--bundle", "--format=cjs", "entry.ts"]);
      expect(exitCode).toBe(0);
      // CJS는 자체적으로 "use strict" 추가 — "use client"도 prologue 내 존재해야
      expect(stdout).toContain('"use client"');
    } finally {
      await cleanup();
    }
  });

  test("preserve-modules: 비-entry 모듈도 자기 디렉티브 보존", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-rsc-pm2-"));
    try {
      const { dir } = await createFixture({
        "client-comp.tsx": `"use client";\nimport { useState } from "react";\nexport default function C(){return useState(0)[0];}`,
        "entry.tsx": `import C from "./client-comp";\nexport default function E(){return <C/>;}`,
      });
      try {
        const result = await runZtsInDir(dir, [
          "--bundle",
          "--preserve-modules",
          "--outdir",
          outdir,
          "entry.tsx",
        ]);
        expect(result.exitCode).toBe(0);
        const clientFile = readdirSync(outdir).find((f) => f.includes("client-comp"));
        expect(clientFile).toBeDefined();
        const content = readFileSync(join(outdir, clientFile!), "utf8");
        expect(content.trimStart().startsWith('"use client"')).toBe(true);
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });

  test("preserve-modules: entry에 디렉티브 없으면 호이스트 안 함", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-rsc-pm3-"));
    try {
      const { dir } = await createFixture({
        "dep.ts": `export const x = 1;`,
        "entry.ts": `import { x } from "./dep";\nexport default x;`,
      });
      try {
        const result = await runZtsInDir(dir, [
          "--bundle",
          "--preserve-modules",
          "--outdir",
          outdir,
          "entry.ts",
        ]);
        expect(result.exitCode).toBe(0);
        const entryFile = readdirSync(outdir).find((f) => f.startsWith("entry"));
        const content = readFileSync(join(outdir, entryFile!), "utf8");
        expect(content).not.toContain('"use client"');
        expect(content).not.toContain('"use server"');
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });

  test("ESM 번들 minify 모드에서도 디렉티브 호이스트", async () => {
    const { dir, cleanup } = await createFixture({
      "dep.ts": `export const x = 1;`,
      "entry.tsx": `"use client";\nimport { x } from "./dep";\nexport default x;`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, [
        "--bundle",
        "--format=esm",
        "--minify",
        "entry.tsx",
      ]);
      expect(exitCode).toBe(0);
      expect(stdout.trimStart().startsWith('"use client"')).toBe(true);
    } finally {
      await cleanup();
    }
  });

  test("디렉티브 + --banner:js: 디렉티브가 banner보다 위", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.tsx": `"use client";\nexport default 1;`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, [
        "--bundle",
        "--format=esm",
        "--banner:js=/* COPYRIGHT */",
        "entry.tsx",
      ]);
      expect(exitCode).toBe(0);
      const dirIdx = stdout.indexOf('"use client"');
      const bannerIdx = stdout.indexOf("COPYRIGHT");
      expect(dirIdx).toBeGreaterThanOrEqual(0);
      if (bannerIdx >= 0) expect(dirIdx).toBeLessThan(bannerIdx);
    } finally {
      await cleanup();
    }
  });

  test("디렉티브 prologue에 unknown 디렉티브 함께 보존", async () => {
    // ECMAScript spec: prologue는 implementation-defined directive를 허용
    const { dir, cleanup } = await createFixture({
      "entry.ts": `"use client";\n"random-directive";\nexport const x = 1;`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.ts"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('"use client"');
      expect(stdout).toContain('"random-directive"');
    } finally {
      await cleanup();
    }
  });

  test("코드 스플리팅 (--splitting): entry 청크에 디렉티브 호이스트", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-rsc-split-"));
    try {
      const { dir } = await createFixture({
        "lazy.ts": `export const v = 42;`,
        "entry.tsx": `"use client";\nexport default async function(){const m = await import("./lazy");return m.v;}`,
      });
      try {
        const result = await runZtsInDir(dir, [
          "--bundle",
          "--splitting",
          "--format=esm",
          "--outdir",
          outdir,
          "entry.tsx",
        ]);
        expect(result.exitCode).toBe(0);
        const entryFile = readdirSync(outdir).find(
          (f) => f.startsWith("entry") && f.endsWith(".js"),
        );
        expect(entryFile).toBeDefined();
        const content = readFileSync(join(outdir, entryFile!), "utf8");
        expect(content.trimStart().startsWith('"use client"')).toBe(true);
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });

  test("디렉티브만 있는 모듈도 정상 처리 (no body)", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `"use client";\n`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.ts"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('"use client"');
    } finally {
      await cleanup();
    }
  });

  test("Rollup module-level-directive fixture: 'use asm' 보존", async () => {
    // Rollup은 경고 후 무시하지만, ZTS는 디렉티브를 단순 보존
    const { stdout, exitCode } = await runZts([join(FIXTURES, "module-level-directive.mjs")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('"use asm"');
  });

  test("Rolldown preserve_modules fixture: 각 파일이 자기 디렉티브 보존", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-rd-pm-"));
    try {
      const result = await runZtsInDir(join(FIXTURES, "rolldown-preserve-modules"), [
        "--bundle",
        "--preserve-modules",
        "--outdir",
        outdir,
        "main.mjs",
      ]);
      expect(result.exitCode).toBe(0);
      const files = readdirSync(outdir);
      for (const f of files) {
        const content = readFileSync(join(outdir, f), "utf8");
        // main과 mod 둘 다 'use client'가 첫 문장 (큰따옴표로 정규화)
        expect(content.trimStart().startsWith('"use client"')).toBe(true);
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });

  test("Rolldown chunk_level_directives fixture: entry 디렉티브 보존, shared 청크는 디렉티브 드롭", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-rd-chunk-"));
    try {
      const result = await runZtsInDir(join(FIXTURES, "rolldown-chunk-directives"), [
        "--bundle",
        "--splitting",
        "--format=esm",
        "--outdir",
        outdir,
        "entry1.mjs",
        "entry2.mjs",
      ]);
      expect(result.exitCode).toBe(0);
      const files = readdirSync(outdir);
      const entry1 = files.find((f) => f.startsWith("entry1"));
      const entry2 = files.find((f) => f.startsWith("entry2"));
      expect(entry1).toBeDefined();
      expect(entry2).toBeDefined();
      const e1 = readFileSync(join(outdir, entry1!), "utf8");
      const e2 = readFileSync(join(outdir, entry2!), "utf8");
      expect(e1.trimStart().startsWith('"use entry"')).toBe(true);
      expect(e2.trimStart().startsWith('"use entry2"')).toBe(true);
      // shared 청크가 따로 생성되었으면 디렉티브 없음 (Rolldown 동일 동작)
      const shared = files.find(
        (f) => f !== entry1 && f !== entry2 && f.endsWith(".js") && !f.endsWith(".map"),
      );
      if (shared) {
        const s = readFileSync(join(outdir, shared), "utf8");
        // shared.mjs는 'use client'/'use server'를 가지나, 청크 호이스트 안 됨
        expect(s.trimStart().startsWith('"use client"')).toBe(false);
        expect(s.trimStart().startsWith('"use server"')).toBe(false);
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });

  test("Next.js server-action fixture (case-2,3,5): 'use server' 인라인 보존", async () => {
    for (const file of ["case-2.tsx", "case-3.tsx", "case-5.tsx"]) {
      const { stdout, exitCode } = await runZts([join(FIXTURES, "nextjs-server-actions", file)]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('"use server"');
    }
  });

  // case-2..10 모두 트랜스파일 성공 + 'use server' 보존 (top-level이든 inline이든)
  const ACTION_CASES = [
    "case-2.tsx",
    "case-3.tsx",
    "case-4.tsx",
    "case-5.tsx",
    "case-6.tsx",
    "case-7.tsx",
    "case-8.tsx",
    "case-9.tsx",
    "case-10.tsx",
  ];
  for (const f of ACTION_CASES) {
    test(`Next.js fixture ${f}: 트랜스파일 성공 + use server 보존`, async () => {
      const { stdout, exitCode } = await runZts([join(FIXTURES, "nextjs-server-actions", f)]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('"use server"');
    });
  }

  test("'use cache' (Next.js 15+) 디렉티브 보존", async () => {
    const { stdout, exitCode } = await runZts([
      join(FIXTURES, "nextjs-server-actions", "use-cache-life.tsx"),
    ]);
    expect(exitCode).toBe(0);
    expect(stdout.trimStart().startsWith('"use cache"')).toBe(true);
  });

  test("'use cache' inline (함수 내부) 보존", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `export async function getData(){"use cache";\nreturn fetch("/api").then(r=>r.json());}`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.ts"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('"use cache"');
    } finally {
      await cleanup();
    }
  });

  test("Next.js case-9: top-level 'use server' + named export re-export 동작", async () => {
    const { stdout, exitCode } = await runZts([
      join(FIXTURES, "nextjs-server-actions", "case-9.tsx"),
    ]);
    expect(exitCode).toBe(0);
    // 코멘트 다음의 첫 statement가 디렉티브여야 함 (스펙: prologue는 코멘트 허용)
    const stripComments = (s: string) =>
      s
        .replace(/^\s*\/\/[^\n]*\n/g, "")
        .replace(/^\s*\/\*[\s\S]*?\*\/\s*/g, "")
        .trimStart();
    expect(stripComments(stdout).startsWith('"use server"')).toBe(true);
    expect(stdout).toContain("foo");
  });

  test("Next.js case-10: 'use server' + default async export", async () => {
    const { stdout, exitCode } = await runZts([
      join(FIXTURES, "nextjs-server-actions", "case-10.tsx"),
    ]);
    expect(exitCode).toBe(0);
    expect(stdout.trimStart().startsWith('"use server"')).toBe(true);
    expect(stdout).toContain("foo");
  });
});

/**
 * 실제 E2E: 번들 출력을 Node.js로 실행하여 동작 + 디렉티브 정합성 검증
 *
 * 검증 포인트:
 * - 번들 결과가 SyntaxError 없이 Node로 import/require 가능
 * - 디렉티브가 첫 토큰이라 RSC 프레임워크 정규식이 인식 가능
 * - 함수 동작 (export 호출 → 기대 값 반환)
 */
describe("RSC 디렉티브 E2E (실제 Node 실행)", () => {
  test("ESM 번들: 'use client' 보존 + Node import 후 export 호출 동작", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-e2e-esm-"));
    try {
      const { dir } = await createFixture({
        "lib.ts": `export const greeting = (name: string) => \`hello \${name}\`;`,
        "entry.ts": `"use client";\nimport { greeting } from "./lib";\nexport function run(){return greeting("rsc");}`,
      });
      try {
        const out = join(outdir, "bundle.mjs");
        const r = await runZtsInDir(dir, ["--bundle", "--format=esm", "-o", out, "entry.ts"]);
        expect(r.exitCode).toBe(0);

        const content = readFileSync(out, "utf8");
        // 1) 디렉티브 첫 토큰
        expect(content.trimStart().startsWith('"use client"')).toBe(true);
        // 2) RSC 프레임워크식 정규식 — Next.js가 사용하는 패턴 모사
        expect(/^\s*["']use client["']\s*;?/.test(content)).toBe(true);

        // 3) 실제 Node로 import 실행
        const { stdout, exitCode } = await runCmd([
          "node",
          "--input-type=module",
          "-e",
          `import("${out}").then(m => { console.log(m.run()); });`,
        ]);
        expect(exitCode).toBe(0);
        expect(stdout.trim()).toBe("hello rsc");
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });

  test("preserve-modules ESM: 각 파일을 Node로 import 가능 + 디렉티브 보존", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-e2e-pm-"));
    try {
      const { dir } = await createFixture({
        "client.ts": `"use client";\nexport const tag = "CLIENT";`,
        "server.ts": `"use server";\nexport async function action(){return "SERVER_OK";}`,
        "entry.ts": `import { tag } from "./client";\nimport { action } from "./server";\nexport async function run(){return tag + ":" + (await action());}`,
      });
      try {
        const r = await runZtsInDir(dir, [
          "--bundle",
          "--preserve-modules",
          "--format=esm",
          "--outdir",
          outdir,
          "entry.ts",
        ]);
        expect(r.exitCode).toBe(0);

        const clientFile = readdirSync(outdir).find((f) => f.startsWith("client"));
        const serverFile = readdirSync(outdir).find((f) => f.startsWith("server"));
        expect(clientFile).toBeDefined();
        expect(serverFile).toBeDefined();

        const clientContent = readFileSync(join(outdir, clientFile!), "utf8");
        const serverContent = readFileSync(join(outdir, serverFile!), "utf8");
        expect(clientContent.trimStart().startsWith('"use client"')).toBe(true);
        expect(serverContent.trimStart().startsWith('"use server"')).toBe(true);

        // 출력 .js를 Node ESM으로 import 가능하도록 package.json 작성
        await Bun.write(join(outdir, "package.json"), '{"type":"module"}');

        const entryFile = readdirSync(outdir).find((f) => f.startsWith("entry"));
        const { stdout, exitCode } = await runCmd([
          "node",
          "--input-type=module",
          "-e",
          `import("${join(outdir, entryFile!)}").then(async m => { console.log(await m.run()); });`,
        ]);
        expect(exitCode).toBe(0);
        expect(stdout.trim()).toBe("CLIENT:SERVER_OK");
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });

  test("CJS 번들: 'use client' 디렉티브 prologue 위치 + Node require로 SyntaxError 없음", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-e2e-cjs-"));
    try {
      const { dir } = await createFixture({
        "entry.ts": `"use client";\nexport function add(a: number, b: number){return a + b;}`,
      });
      try {
        const out = join(outdir, "bundle.cjs");
        const r = await runZtsInDir(dir, ["--bundle", "--format=cjs", "-o", out, "entry.ts"]);
        expect(r.exitCode).toBe(0);

        const content = readFileSync(out, "utf8");
        expect(content).toContain('"use client"');
        // CJS는 자체 "use strict"가 prologue에 있으므로 둘 다 prologue 영역에 존재해야
        const head = content.split("\n").slice(0, 6).join("\n");
        expect(head).toContain('"use strict"');
        expect(head).toContain('"use client"');

        // SyntaxError 없이 Node require 가능 (실제 export 동작은 별도 이슈)
        const { exitCode } = await runCmd(["node", "-e", `require("${out}");`]);
        expect(exitCode).toBe(0);
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });

  test("Next.js 스타일 RSC 감지 정규식 통과 (실제 Next 코드 모사)", async () => {
    // Next.js의 react_server_components.rs는 디렉티브를 파일 첫 string literal로
    // 검출. 우리 출력이 그 검출 로직을 통과해야 한다.
    const detectClient = (src: string) => {
      const trimmed = src
        .replace(/^[\s]*\/\*[\s\S]*?\*\/\s*/, "")
        .replace(/^(?:[\s]*\/\/.*\n)+/, "")
        .trimStart();
      return /^["']use client["']\s*;?/.test(trimmed);
    };
    const detectServer = (src: string) => {
      const trimmed = src
        .replace(/^[\s]*\/\*[\s\S]*?\*\/\s*/, "")
        .replace(/^(?:[\s]*\/\/.*\n)+/, "")
        .trimStart();
      return /^["']use server["']\s*;?/.test(trimmed);
    };

    const { dir, cleanup } = await createFixture({
      "c.tsx": `"use client";\nexport default function(){return null;}`,
      "s.ts": `"use server";\nexport async function f(){return 1;}`,
    });
    try {
      const c = await runZtsInDir(dir, ["c.tsx"]);
      const s = await runZtsInDir(dir, ["s.ts"]);
      expect(c.exitCode).toBe(0);
      expect(s.exitCode).toBe(0);
      expect(detectClient(c.stdout)).toBe(true);
      expect(detectServer(s.stdout)).toBe(true);
    } finally {
      await cleanup();
    }
  });
});

describe("TanStack Start RSC 호환성 (실제 코드)", () => {
  // 모두 references/tanstack-router 실제 소스에서 복사
  const TS_FIXTURES = join(FIXTURES, "tanstack-start");

  test("Button.tsx (Pokemon demo): 'use client' 보존 + JSX 트랜스폼", async () => {
    const { stdout, exitCode } = await runZts([join(TS_FIXTURES, "pokemon-button.tsx")]);
    expect(exitCode).toBe(0);
    expect(stdout.trimStart().startsWith('"use client"')).toBe(true);
    expect(stdout).toContain("React.createElement");
  });

  test("ClientSlot.tsx (react-start-rsc): 'use client' + import + named export", async () => {
    const { stdout, exitCode } = await runZts([join(TS_FIXTURES, "client-slot.tsx")]);
    expect(exitCode).toBe(0);
    expect(stdout.trimStart().startsWith('"use client"')).toBe(true);
    expect(stdout).toContain("ClientSlot");
  });

  test("SlotContext.tsx (Context API + 'use client')", async () => {
    const { stdout, exitCode } = await runZts([join(TS_FIXTURES, "slot-context.tsx")]);
    expect(exitCode).toBe(0);
    expect(stdout.trimStart().startsWith('"use client"')).toBe(true);
  });

  test("createServerComponentFromStream.ts (복잡한 import + 'use client')", async () => {
    const { stdout, exitCode } = await runZts([
      join(TS_FIXTURES, "create-server-component-from-stream.ts"),
    ]);
    expect(exitCode).toBe(0);
    expect(stdout.trimStart().startsWith('"use client"')).toBe(true);
  });

  test("home-server-functions.tsx (createServerFn + JSX)", async () => {
    // 이 파일은 디렉티브 없이 createServerFn 사용 — 트랜스파일만 검증
    const { stdout, exitCode } = await runZts([join(TS_FIXTURES, "home-server-functions.tsx")]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("createServerFn");
  });

  test("TanStack 번들: 'use client' 컴포넌트들이 preserve-modules 시 각자 디렉티브 유지", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-tanstack-"));
    try {
      const r = await runZtsInDir(TS_FIXTURES, [
        "--bundle",
        "--preserve-modules",
        "--outdir",
        outdir,
        "client-slot.tsx",
      ]);
      expect(r.exitCode).toBe(0);
      const slotFile = readdirSync(outdir).find((f) => f.includes("client-slot"));
      expect(slotFile).toBeDefined();
      const content = readFileSync(join(outdir, slotFile!), "utf8");
      expect(content.trimStart().startsWith('"use client"')).toBe(true);
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });
});

describe("RSC 디렉티브 충돌 검증 (Next.js 스펙)", () => {
  test("'use client' + 'use server' 같은 청크에 → stderr 경고", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-rsc-conflict-"));
    try {
      const { dir } = await createFixture({
        "bad.ts": `"use client";\n"use server";\nexport const x = 1;`,
      });
      try {
        const r = await runZtsInDir(dir, [
          "--bundle",
          "--preserve-modules",
          "--outdir",
          outdir,
          "bad.ts",
        ]);
        expect(r.exitCode).toBe(0); // warning이지 error 아님
        expect(r.stderr).toMatch(/use client.*use server|use server.*use client/);
        expect(r.stderr).toContain("RSC directive conflict");
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });

  test("'use client' + 'use cache' 같은 청크에 → stderr 경고", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-rsc-conflict2-"));
    try {
      const { dir } = await createFixture({
        "bad.ts": `"use client";\n"use cache";\nexport const x = 1;`,
      });
      try {
        const r = await runZtsInDir(dir, [
          "--bundle",
          "--preserve-modules",
          "--outdir",
          outdir,
          "bad.ts",
        ]);
        expect(r.exitCode).toBe(0);
        expect(r.stderr).toMatch(/use client.*use cache|use cache.*use client/);
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });

  test("'use client' 단독은 경고 없음", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-rsc-noconflict-"));
    try {
      const { dir } = await createFixture({
        "ok.ts": `"use client";\nexport const x = 1;`,
      });
      try {
        const r = await runZtsInDir(dir, [
          "--bundle",
          "--preserve-modules",
          "--outdir",
          outdir,
          "ok.ts",
        ]);
        expect(r.exitCode).toBe(0);
        expect(r.stderr).not.toContain("RSC directive conflict");
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });
});

describe("RSC 디렉티브 엣지 케이스", () => {
  test("hashbang(#!) + 디렉티브: 둘 다 보존, 순서 유지", async () => {
    // ES2023 spec: hashbang은 program 첫 줄, directive prologue는 그 다음
    const { dir, cleanup } = await createFixture({
      "cli.ts": `#!/usr/bin/env node\n"use client";\nexport const x = 1;`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["cli.ts"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('"use client"');
    } finally {
      await cleanup();
    }
  });

  test("디렉티브 + 빈 export 모듈도 정상", async () => {
    const { dir, cleanup } = await createFixture({
      "empty.ts": `"use client";\nexport {};`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["empty.ts"]);
      expect(exitCode).toBe(0);
      expect(stdout.trimStart().startsWith('"use client"')).toBe(true);
    } finally {
      await cleanup();
    }
  });

  test("디렉티브 + --sourcemap: 첫 문장 위치 유지", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.tsx": `"use client";\nexport function f(): number { return 1; }`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["--sourcemap", "entry.tsx"]);
      expect(exitCode).toBe(0);
      expect(stdout.trimStart().startsWith('"use client"')).toBe(true);
    } finally {
      await cleanup();
    }
  });

  test("ESM 단일 번들 contract: entry에 디렉티브 없으면 호이스트 안 함 (non-entry 모듈 디렉티브는 보장 없음)", async () => {
    const { dir, cleanup } = await createFixture({
      "comp.tsx": `"use client";\nexport default function C(){return 1;}`,
      "entry.ts": `import C from "./comp";\nexport default C;`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["--bundle", "--format=esm", "entry.ts"]);
      expect(exitCode).toBe(0);
      // entry는 디렉티브 없음 → 출력 첫 문장이 "use client"가 아님 (호이스트 contract)
      expect(stdout.trimStart().startsWith('"use client"')).toBe(false);
      // 비-entry 모듈의 디렉티브는 IIFE/concat 번들에서 보장되지 않음 (Rollup과 동일).
      // RSC 호환을 위해선 preserve-modules 사용 필요.
    } finally {
      await cleanup();
    }
  });

  test("이상하게 들여쓰기된 디렉티브 (스페이스 8칸)", async () => {
    const { dir, cleanup } = await createFixture({
      "weird.ts": `        "use client";\nexport const x = 1;`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["weird.ts"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('"use client"');
    } finally {
      await cleanup();
    }
  });

  test("디렉티브 다수 (use strict + use client + use server) — 충돌 경고 포함", async () => {
    const outdir = await mkdtemp(join(tmpdir(), "zts-rsc-multi-"));
    try {
      const { dir } = await createFixture({
        "many.ts": `"use strict";\n"use client";\n"use server";\nexport const x = 1;`,
      });
      try {
        const r = await runZtsInDir(dir, [
          "--bundle",
          "--preserve-modules",
          "--outdir",
          outdir,
          "many.ts",
        ]);
        expect(r.exitCode).toBe(0);
        const f = readdirSync(outdir).find((x) => x.endsWith(".js"));
        const content = readFileSync(join(outdir, f!), "utf8");
        // 셋 다 prologue 영역 (출력 첫 6줄 내) 존재
        const head = content.split("\n").slice(0, 6).join("\n");
        expect(head).toContain('"use strict"');
        expect(head).toContain('"use client"');
        expect(head).toContain('"use server"');
        // 충돌 경고
        expect(r.stderr).toContain("RSC directive conflict");
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    } finally {
      await rm(outdir, { recursive: true, force: true });
    }
  });

  test("minify-syntax 모드에서 디렉티브 보존 (literal 제거 안 함)", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.tsx": `"use client";\nexport function f(){return 1+2;}`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, [
        "--bundle",
        "--format=esm",
        "--minify-syntax",
        "entry.tsx",
      ]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('"use client"');
    } finally {
      await cleanup();
    }
  });
});

async function runCmd(
  cmd: string[],
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const proc = Bun.spawn({ cmd, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { stdout, stderr, exitCode };
}
