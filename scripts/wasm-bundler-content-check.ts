#!/usr/bin/env bun
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  initBundler,
  buildChunks,
  bundlerLastErrorMessage,
  VirtualFileSystem,
} from "../packages/wasm/index";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const wasmBytes = readFileSync(join(repoRoot, "zig-out/bin/zts-bundler.wasm"));

const FILES: Record<string, string> = {
  "/jsx-app.tsx": `import { useState } from "react";
export function Counter() {
  const [n, setN] = useState(0);
  return <button onClick={() => setN(n + 1)}>{n}</button>;
}
`,
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
  "/destructure-await.ts": `async function f() {
  const { x } = await fetch("");
  return x;
}
`,
  "/destructure-simple.ts": `function f(o: { x: number; y: number }) {
  const { x, y } = o;
  return x + y;
}
`,
};

const vfs = new VirtualFileSystem();
for (const [path, content] of Object.entries(FILES)) vfs.set(path, content);
await initBundler(vfs, wasmBytes);

const cases = [
  { label: "external react", entry: "/jsx-app.tsx", opts: { format: "esm" as const, external: ["react"], jsx: "automatic" as const } },
  { label: "external react + classic", entry: "/jsx-app.tsx", opts: { format: "esm" as const, external: ["react"], jsx: "classic" as const } },
  { label: "preserveModules cjs", entry: "/main.ts", opts: { format: "cjs" as const, preserveModules: true } },
  { label: "destructure simple es5", entry: "/destructure-simple.ts", opts: { format: "esm" as const, target: "es5" as const } },
  { label: "destructure await es5", entry: "/destructure-await.ts", opts: { format: "esm" as const, target: "es5" as const } },
];

for (const c of cases) {
  console.log(`\n${"=".repeat(80)}\n${c.label}\n${"=".repeat(80)}`);
  const chunks = buildChunks(c.entry, c.opts);
  if (!chunks) {
    console.log(`FAIL: ${bundlerLastErrorMessage()}`);
    continue;
  }
  for (const ch of chunks) {
    console.log(`\n--- ${ch.path} ---\n${ch.code}`);
  }
}
