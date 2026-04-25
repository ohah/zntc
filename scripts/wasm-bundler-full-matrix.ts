#!/usr/bin/env bun
/**
 * #1885 — bundler ABI 전체 옵션 매트릭스 + 출력 검증.
 * 각 조합에서 build/buildChunks 호출 + 출력 패턴 검증 (다운레벨링 / runtime
 * helper / wrapper 등). 의도된 제약 vs 버그 구분.
 */
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  initBundler,
  build,
  buildChunks,
  bundlerLastErrorMessage,
  VirtualFileSystem,
  type BundleOptionsInput,
  type Target,
} from "../packages/wasm/index";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const wasmBytes = readFileSync(join(repoRoot, "zig-out/bin/zts-bundler.wasm"));

// 다운레벨링 / 변환 검증용 fixture — 각 ES feature + JSX + Flow + decorator.
const FILES: Record<string, string> = {
  "/main.ts": `import { greet } from "./shared";
console.log(greet("entry"));
document.querySelector("#load")?.addEventListener("click", async () => {
  const { heavy } = await import("./heavy");
  heavy();
});
`,
  "/shared.ts": `export const greet = (s: string): string => \`hello, \${s}\`;
`,
  "/heavy.ts": `import { greet } from "./shared";
export function heavy() { console.log(greet("dynamic")); }
`,
  "/jsx-app.tsx": `import { useState } from "react";
export function Counter() {
  const [n, setN] = useState(0);
  return <button onClick={() => setN(n + 1)}>{n}</button>;
}
`,
  "/flow-app.js": `// @flow
function add(x: number, y: number): number { return x + y; }
console.log(add(1, 2));
`,
  "/decorator.ts": `function loggable(_v: any, _ctx: any) { return _v; }
class S { @loggable greet(n: string) { return n; } }
new S().greet("x");
`,
  "/destructure.ts": `export function take(o: { x: number; y: number }) {
  const { x, y } = o;
  return x + y;
}
`,
  "/template.ts": `export const t = (n: string) => \`hello \${n}\`;
`,
};

const vfs = new VirtualFileSystem();
for (const [path, content] of Object.entries(FILES)) vfs.set(path, content);
await initBundler(vfs, wasmBytes);

// ─── case 정의 ───
interface Case {
  group: string;
  label: string;
  entry: string;
  opts: BundleOptionsInput;
  /// 출력에 포함되어야 하는 패턴 (true 면 통과)
  expectIncludes?: { name: string; rx: RegExp }[];
  /// 출력에 없어야 하는 패턴 (true 면 통과)
  expectExcludes?: { name: string; rx: RegExp }[];
  /// 의도적 실패 (null 반환 + 에러 메시지 매칭)
  expectFailMatch?: RegExp;
}

const cases: Case[] = [
  // ─── format × target 매트릭스 (single entry, no split) ───
  ...(["esm", "cjs", "iife", "umd", "amd"] as const).flatMap((format) =>
    (["esnext", "es5"] as const).map(
      (target): Case => ({
        group: "format × target",
        label: `${format} × ${target}`,
        entry: "/main.ts",
        opts: {
          format,
          ...(target !== "esnext" ? { target: target as Target } : {}),
        },
      }),
    ),
  ),

  // ─── code splitting ───
  ...(["esm", "cjs", "iife", "umd", "amd"] as const).map(
    (format): Case => ({
      group: "code splitting",
      label: `${format} + split=true`,
      entry: "/main.ts",
      opts: { format, codeSplitting: true },
      expectFailMatch: format === "esm" ? undefined : /CodeSplittingRequiresESM/,
    }),
  ),

  // ─── preserveModules ───
  ...(["esm", "cjs"] as const).map(
    (format): Case => ({
      group: "preserveModules",
      label: `${format} + preserveModules`,
      entry: "/main.ts",
      opts: { format, preserveModules: true },
    }),
  ),

  // ─── ES5 다운레벨링 검증 ───
  {
    group: "ES5 다운레벨링",
    label: "es5: 화살표 → function",
    entry: "/template.ts",
    opts: { format: "esm", target: "es5" },
    expectExcludes: [{ name: "arrow `=>`", rx: /=>/ }],
    expectIncludes: [{ name: "function", rx: /function/ }],
  },
  {
    group: "ES5 다운레벨링",
    label: "es5: destructuring → 개별 var",
    entry: "/destructure.ts",
    opts: { format: "esm", target: "es5" },
    expectExcludes: [
      { name: "destructuring `{x, y} =`", rx: /\{\s*\w[^}]*\}\s*=/ },
    ],
  },
  {
    group: "ES5 다운레벨링",
    label: "es5: template literal → 문자열 concat",
    entry: "/template.ts",
    opts: { format: "esm", target: "es5" },
    expectExcludes: [{ name: "template `${`", rx: /`[^`]*\$\{/ }],
  },
  {
    group: "ES5 다운레벨링 + splitting",
    label: "es5 + esm + split: chunk 에 __generator/__async 정의 분배",
    entry: "/main.ts",
    opts: { format: "esm", target: "es5", codeSplitting: true },
  },

  // ─── JSX ───
  {
    group: "JSX",
    label: "jsx=classic + factory=h",
    entry: "/jsx-app.tsx",
    opts: { format: "esm", jsx: "classic", jsxFactory: "h" },
    expectIncludes: [{ name: "h(", rx: /\bh\(/ }],
    expectExcludes: [{ name: "React.createElement", rx: /React\.createElement/ }],
  },
  {
    group: "JSX",
    label: "jsx=automatic + importSource=preact",
    entry: "/jsx-app.tsx",
    opts: { format: "esm", jsx: "automatic", jsxImportSource: "preact" },
    expectIncludes: [{ name: "preact 참조", rx: /preact/ }],
  },
  {
    group: "JSX",
    label: "jsx=automatic-dev + importSource=react",
    entry: "/jsx-app.tsx",
    opts: { format: "esm", jsx: "automatic-dev" },
    expectIncludes: [{ name: "jsxDEV 참조", rx: /jsxDEV/ }],
  },

  // ─── Flow ───
  {
    group: "Flow",
    label: "flow=true: type annotation strip",
    entry: "/flow-app.js",
    opts: { format: "esm", flow: true },
    expectExcludes: [{ name: ": number", rx: /:\s*number/ }],
  },

  // ─── Decorators ───
  {
    group: "Decorators",
    label: "experimentalDecorators=true",
    entry: "/decorator.ts",
    opts: { format: "esm", experimentalDecorators: true },
  },
  {
    group: "Decorators",
    label: "+ emitDecoratorMetadata",
    entry: "/decorator.ts",
    opts: { format: "esm", experimentalDecorators: true, emitDecoratorMetadata: true },
  },

  // ─── Minify ───
  {
    group: "Minify",
    label: "minify (all): 출력 길이 감소",
    entry: "/main.ts",
    opts: { format: "esm", minify: true },
  },

  // ─── Sourcemap ───
  {
    group: "Sourcemap",
    label: "sourcemap=true",
    entry: "/main.ts",
    opts: { format: "esm", sourcemap: true },
  },

  // ─── External ───
  {
    group: "External",
    label: "external: react 미포함",
    entry: "/jsx-app.tsx",
    opts: { format: "esm", external: ["react"] },
    expectIncludes: [{ name: "react import 보존", rx: /from\s+["']react["']/ }],
  },

  // ─── charsetUtf8 / keepNames ───
  {
    group: "기타",
    label: "charsetUtf8=true",
    entry: "/template.ts",
    opts: { format: "esm", charsetUtf8: true },
  },
  {
    group: "기타",
    label: "keepNames=true",
    entry: "/main.ts",
    opts: { format: "esm", keepNames: true, minify: true },
  },
];

// ─── 실행 ───
interface Result {
  group: string;
  label: string;
  ok: boolean;
  status: string;
  notes: string[];
}
const results: Result[] = [];

for (const c of cases) {
  const notes: string[] = [];
  let ok = true;
  let status = "";

  const chunks = buildChunks(c.entry, c.opts);

  if (chunks === null || chunks.length === 0) {
    const msg = bundlerLastErrorMessage();
    if (c.expectFailMatch) {
      const matched = c.expectFailMatch.test(msg);
      ok = matched;
      status = matched ? "EXPECTED-FAIL" : "UNEXPECTED-FAIL";
      notes.push(`msg=${msg}`);
    } else {
      ok = false;
      status = "FAIL";
      notes.push(`msg=${msg || "(none)"}`);
    }
  } else {
    if (c.expectFailMatch) {
      ok = false;
      status = "EXPECTED-FAIL-BUT-OK";
      notes.push(`got ${chunks.length} chunk(s)`);
    } else {
      status = "OK";
    }

    // 모든 chunk 합쳐서 패턴 검증
    const all = chunks.map((c) => c.code).join("\n\n");
    if (c.expectIncludes) {
      for (const e of c.expectIncludes) {
        if (!e.rx.test(all)) {
          ok = false;
          notes.push(`MISSING: ${e.name}`);
        }
      }
    }
    if (c.expectExcludes) {
      for (const e of c.expectExcludes) {
        if (e.rx.test(all)) {
          ok = false;
          notes.push(`UNEXPECTED-PRESENT: ${e.name}`);
        }
      }
    }

    // chunk count + size 정보
    notes.push(`${chunks.length}chunk(${chunks.map((c) => `${c.path}=${c.code.length}b`).join(",")})`);
  }

  results.push({ group: c.group, label: c.label, ok, status, notes });
}

// ─── 리포트 ───
let currentGroup = "";
for (const r of results) {
  if (r.group !== currentGroup) {
    console.log(`\n=== ${r.group}`);
    currentGroup = r.group;
  }
  const mark = r.ok ? "✅" : "❌";
  console.log(`${mark} [${r.status}] ${r.label}`);
  for (const n of r.notes) console.log(`     ${n}`);
}

const fails = results.filter((r) => !r.ok);
console.log(`\n${"=".repeat(60)}`);
console.log(`Total: ${results.length}, OK: ${results.length - fails.length}, FAIL: ${fails.length}`);
if (fails.length > 0) {
  console.log(`\nFAILS:`);
  for (const f of fails) console.log(`  - [${f.status}] ${f.group} / ${f.label}`);
}
