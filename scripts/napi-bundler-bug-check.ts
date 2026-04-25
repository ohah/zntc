#!/usr/bin/env bun
/**
 * #1885 follow-up — NAPI bundler 에서 wasm 와 동일 버그 재현 확인.
 * #1960 (ES5 destructuring) / #1961 (chunk split __generator) / #1962 (external
 * require) 가 wasm 만의 문제인지 ZTS 코어 자체 문제인지 분기.
 */
import { mkdtempSync, writeFileSync, rmSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { init, build } from "../packages/core/index";

init();

interface Case {
  label: string;
  files: Record<string, string>;
  entry: string;
  options: Record<string, unknown>;
  inspect: { name: string; rx: RegExp; expectMatch?: boolean }[];
}

const cases: Case[] = [
  {
    label: "#1960-A: ES5 + simple destructuring",
    files: {
      "destructure.ts": `export function f(o: { x: number; y: number }) {
  const { x, y } = o;
  return x + y;
}`,
    },
    entry: "destructure.ts",
    options: { format: "esm", target: "es5" },
    inspect: [
      { name: "destructuring `{...} =` 잔존 (BUG)", rx: /\{\s*\w[^}]*\}\s*=/, expectMatch: false },
      { name: "_a 중복 선언 (BUG)", rx: /var\s+_a\s*,\s*_a\s*=/, expectMatch: false },
    ],
  },
  {
    label: "#1960-B: ES5 + await destructuring",
    files: {
      "await-destructure.ts": `export async function f() {
  const { x } = await fetch("");
  return x;
}`,
    },
    entry: "await-destructure.ts",
    options: { format: "esm", target: "es5" },
    inspect: [
      { name: "ES5 출력에 destructuring 잔존 (BUG)", rx: /\{\s*\w+:\s*\w+\s*\}\s*=/, expectMatch: false },
      { name: "화살표 / async 다운레벨링 OK", rx: /__async|__generator/, expectMatch: true },
    ],
  },
  {
    label: "#1961: code splitting + ES5 → __generator helper 분배",
    files: {
      "main.ts": `import { greet } from "./shared";
console.log(greet("entry"));
document.querySelector("#load")?.addEventListener("click", async () => {
  const { heavy } = await import("./heavy");
  heavy();
});`,
      "shared.ts": `export const greet = (s: string): string => \`hello, \${s}\`;`,
      "heavy.ts": `import { greet } from "./shared";
export function heavy() { console.log(greet("dynamic")); }`,
    },
    entry: "main.ts",
    options: { format: "esm", target: "es5", splitting: true },
    inspect: [], // 아래에서 chunk 별 검증
  },
  {
    label: "#1962: external + format=esm → require() 변환",
    files: {
      "app.tsx": `import { useState } from "react";
export function Counter() {
  const [n, setN] = useState(0);
  return <button onClick={() => setN(n + 1)}>{n}</button>;
}`,
    },
    entry: "app.tsx",
    options: { format: "esm", external: ["react"], jsx: "automatic" },
    inspect: [
      { name: "require(\"react\") 사용 (BUG)", rx: /require\(["']react["']\)/, expectMatch: false },
      { name: "ESM import 보존 (기대)", rx: /from\s+["']react["']/, expectMatch: true },
    ],
  },
];

let totalFails = 0;

for (const c of cases) {
  console.log(`\n${"=".repeat(80)}\n${c.label}\n${"=".repeat(80)}`);
  const dir = mkdtempSync(join(tmpdir(), "zts-napi-bug-"));
  for (const [name, content] of Object.entries(c.files)) {
    writeFileSync(join(dir, name), content);
  }
  const outdir = join(dir, "out");

  try {
    const result = await build({
      entryPoints: [join(dir, c.entry)],
      outdir,
      ...c.options,
    } as any);

    if (!result.outputFiles || result.outputFiles.length === 0) {
      console.log("FAIL — empty outputFiles");
      continue;
    }

    for (const o of result.outputFiles) {
      console.log(`\n--- ${o.path} (${o.text.length}b) ---`);
      console.log(o.text);
    }

    // inspect 검증 — 모든 chunk 합쳐 검색
    const all = result.outputFiles.map((o) => o.text).join("\n\n");

    for (const i of c.inspect) {
      const matched = i.rx.test(all);
      const expected = i.expectMatch !== false; // default expect match
      const ok = matched === expected;
      if (!ok) totalFails += 1;
      console.log(`${ok ? "✅" : "❌"} ${i.name} (matched=${matched}, expected=${expected})`);
    }

    // #1961: __generator 분배 검증 (chunk 별)
    if (c.label.startsWith("#1961")) {
      console.log("\n--- chunk별 __generator 정의 분배 검증 ---");
      for (const o of result.outputFiles) {
        const code = o.text;
        const usesGen = /__generator\b/.test(code);
        const definesGen = /(?:var|function)\s+__generator/.test(code);
        const usesAsync = /__async\b/.test(code);
        const definesAsync = /(?:var|function)\s+__async/.test(code);
        console.log(
          `  ${o.path}: __generator(use=${usesGen}, def=${definesGen}) __async(use=${usesAsync}, def=${definesAsync})`,
        );
        if (usesGen && !definesGen) {
          console.log(`  ❌ BUG: ${o.path} uses __generator but no definition!`);
          totalFails += 1;
        }
      }
    }
  } catch (err) {
    console.log(`❌ build threw: ${err}`);
    totalFails += 1;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

console.log(`\n${"=".repeat(60)}`);
console.log(`Total fails: ${totalFails}`);
process.exit(totalFails > 0 ? 1 : 0);
