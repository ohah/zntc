#!/usr/bin/env bun
/**
 * #1885 — ES5 다운레벨링 출력 검증.
 * 사용자 보고 (destructuring 미변환, __generator 누락) 를 코드 레벨에서 직접 확인.
 */
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  initBundler,
  buildChunks,
  VirtualFileSystem,
} from "../packages/wasm/index";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const wasmBytes = readFileSync(join(repoRoot, "zig-out/bin/zts-bundler.wasm"));

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
};

const vfs = new VirtualFileSystem();
for (const [path, content] of Object.entries(FILES)) vfs.set(path, content);
await initBundler(vfs, wasmBytes);

const cases = [
  { label: "esm + esnext + no-split", opts: { format: "esm" as const } },
  { label: "esm + es5 + no-split", opts: { format: "esm" as const, target: "es5" as const } },
  { label: "esm + es5 + split=true", opts: { format: "esm" as const, target: "es5" as const, codeSplitting: true } },
  { label: "iife + es5", opts: { format: "iife" as const, target: "es5" as const } },
  { label: "cjs + es5", opts: { format: "cjs" as const, target: "es5" as const } },
];

for (const c of cases) {
  console.log(`\n${"=".repeat(80)}\n=== ${c.label}\n${"=".repeat(80)}`);
  const chunks = buildChunks("/main.ts", c.opts);
  if (!chunks) {
    console.log("FAIL — null");
    continue;
  }
  for (const ch of chunks) {
    console.log(`\n--- ${ch.path} (${ch.code.length}b) ---`);
    console.log(ch.code);
    // 검증 키워드
    const checks = {
      "arrow `=>`": /=>/.test(ch.code),
      "destructuring `{ ... } =`": /\{\s*\w[^}]*\}\s*=/.test(ch.code),
      "__generator 사용": /__generator/.test(ch.code),
      "__generator 정의": /(?:var|function)\s+__generator/.test(ch.code),
      "__async 사용": /__async/.test(ch.code),
      "__async 정의": /(?:var|function)\s+__async/.test(ch.code),
    };
    console.log(`\n[check]`, Object.fromEntries(Object.entries(checks)));
  }
}
