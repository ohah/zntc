#!/usr/bin/env bun
/**
 * #1885 — bundler ABI 옵션 매트릭스 점검 스크립트.
 *
 * 모든 format × target × splitting 조합을 multi-file VFS 위에서 build /
 * buildChunks 호출해 성공/실패 + 에러 메시지를 표로 리포트.
 * UI 에서 사용자가 만나는 조합 잘못 / runtime helper 누락 / non-ESM splitting
 * 같은 케이스 사전 식별.
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

const formats = ["esm", "cjs", "iife", "umd", "amd"] as const;
const targets: (Target | "esnext")[] = ["esnext", "es5"];
const splits = [false, true];

interface Row {
  format: string;
  target: string;
  split: boolean;
  api: string;
  ok: boolean;
  detail: string;
}
const rows: Row[] = [];

for (const format of formats) {
  for (const target of targets) {
    for (const split of splits) {
      const opts: BundleOptionsInput = { format, codeSplitting: split };
      if (target !== "esnext") opts.target = target as Target;

      // build (single-file mode)
      try {
        const r = build("/main.ts", opts);
        const detail = r === null ? bundlerLastErrorMessage() : `${r.code.length}b`;
        rows.push({ format, target, split, api: "build", ok: r !== null, detail });
      } catch (e) {
        rows.push({ format, target, split, api: "build", ok: false, detail: String(e) });
      }

      // buildChunks (multi-output mode)
      try {
        const r = buildChunks("/main.ts", opts);
        const detail =
          r === null
            ? bundlerLastErrorMessage()
            : `${r.length}chunk: ${r.map((c) => `${c.path}=${c.code.length}b`).join(", ")}`;
        rows.push({ format, target, split, api: "buildChunks", ok: r !== null, detail });
      } catch (e) {
        rows.push({ format, target, split, api: "buildChunks", ok: false, detail: String(e) });
      }
    }
  }
}

const fmt = (r: Row) =>
  `${r.ok ? "OK " : "FAIL"}  ${r.format.padEnd(4)}  target=${r.target.padEnd(6)}  split=${String(r.split).padEnd(5)}  ${r.api.padEnd(11)}  ${r.detail}`;

console.log(rows.map(fmt).join("\n"));

const fails = rows.filter((r) => !r.ok);
console.log(`\nTotal: ${rows.length}, Fails: ${fails.length}`);
