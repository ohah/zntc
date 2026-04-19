#!/usr/bin/env bun
/**
 * Minify size benchmark — #1608 검증 전용
 *
 * ZTS/esbuild/rolldown 모두 `--minify`로 실행해 bundle 사이즈와
 * mangled name 길이 분포를 비교한다. scope_hoisting 이후 per-scope renamer
 * 도입 전/후 baseline 재사용.
 *
 * 실행: bun run minify-bench.ts
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, existsSync, statSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
const ESBUILD_BIN = existsSync(join(__dirname, "node_modules/.bin/esbuild"))
  ? join(__dirname, "node_modules/.bin/esbuild")
  : join(ROOT, "node_modules/.bin/esbuild");
const ROLLDOWN_BIN = existsSync(join(__dirname, "node_modules/.bin/rolldown"))
  ? join(__dirname, "node_modules/.bin/rolldown")
  : join(ROOT, "node_modules/.bin/rolldown");

const EXEC_TIMEOUT_MS = 180_000;

interface Fixture {
  name: string;
  entry: string;
  platform?: "node" | "browser";
  format?: "esm" | "cjs";
}

const fixtures: Fixture[] = [
  {
    name: "effect",
    entry: `import { Effect, pipe } from 'effect';
const p = pipe(Effect.succeed(42), Effect.map((n: number) => n + 1));
Effect.runPromise(p).then(r => console.log(r));`,
  },
  {
    name: "lodash-es",
    entry: `import { groupBy, sortBy, uniq } from 'lodash-es';
console.log(groupBy, sortBy, uniq);`,
  },
  {
    name: "zod",
    entry: `import { z } from 'zod';
const schema = z.string().email();
console.log(schema.parse('test@test.com'));`,
  },
  {
    name: "rxjs",
    entry: `import { of, map, filter, toArray } from 'rxjs';
of(1,2,3,4,5).pipe(filter(x=>x%2===0), map(x=>x*10), toArray()).subscribe(arr=>console.log(JSON.stringify(arr)));`,
  },
  {
    name: "three",
    entry: `import { Vector3 } from 'three';
const v = new Vector3(1, 2, 3);
console.log(v.length().toFixed(2));`,
  },
  {
    name: "react",
    entry: `import React from 'react';
const el = React.createElement('div', {id:'t'}, 'hi');
console.log(el.type, el.props.id);`,
  },
];

interface LengthHistogram {
  len1: number;
  len2: number;
  len3: number;
  len4: number;
  len5plus: number;
}

interface ToolResult {
  ok: boolean;
  size: number;
  time: number;
  hist: LengthHistogram;
}

interface BenchResult {
  name: string;
  zts: ToolResult;
  esbuild: ToolResult | null;
  rolldown: ToolResult | null;
}

function histTotal(h: LengthHistogram): number {
  return h.len1 + h.len2 + h.len3 + h.len4 + h.len5plus;
}

// JS 예약어 — identifier 카운트에서 제외하여 순수 식별자만 집계
const KEYWORDS = new Set([
  "var",
  "let",
  "const",
  "function",
  "return",
  "if",
  "else",
  "for",
  "while",
  "do",
  "switch",
  "case",
  "default",
  "break",
  "continue",
  "throw",
  "try",
  "catch",
  "finally",
  "new",
  "delete",
  "typeof",
  "instanceof",
  "in",
  "of",
  "void",
  "null",
  "undefined",
  "true",
  "false",
  "this",
  "super",
  "class",
  "extends",
  "import",
  "export",
  "from",
  "as",
  "async",
  "await",
  "yield",
  "static",
  "get",
  "set",
  "public",
  "private",
  "protected",
  "debugger",
  "with",
  "enum",
  "implements",
  "interface",
  "package",
]);

const EMPTY_HIST: LengthHistogram = {
  len1: 0,
  len2: 0,
  len3: 0,
  len4: 0,
  len5plus: 0,
};

// 문자열 리터럴 내부 텍스트도 일부 잡히지만, 세 도구 모두에 동일하게 노이즈가 적용되므로 비교는 유효.
function histogramOf(src: string): LengthHistogram {
  const ids = new Set<string>();
  const re = /[a-zA-Z_$][a-zA-Z0-9_$]*/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    if (!KEYWORDS.has(m[0])) ids.add(m[0]);
  }
  const hist: LengthHistogram = { ...EMPTY_HIST };
  ids.forEach((id) => {
    if (id.length === 1) hist.len1++;
    else if (id.length === 2) hist.len2++;
    else if (id.length === 3) hist.len3++;
    else if (id.length === 4) hist.len4++;
    else hist.len5plus++;
  });
  return hist;
}

function exec(bin: string, args: string[], cwd?: string) {
  const start = performance.now();
  const r = spawnSync(bin, args, { cwd, stdio: "pipe", timeout: EXEC_TIMEOUT_MS });
  const time = Math.round(performance.now() - start);
  return { ok: r.status === 0, time, stderr: r.stderr?.toString() ?? "" };
}

function runTool(
  label: string,
  bin: string,
  args: string[],
  outFile: string,
  cwd?: string,
): ToolResult {
  const { ok, time, stderr } = exec(bin, args, cwd);
  if (!ok || !existsSync(outFile)) {
    if (stderr) console.error(`[${label}] ${stderr.slice(0, 300)}`);
    return { ok: false, size: 0, time, hist: { ...EMPTY_HIST } };
  }
  const src = readFileSync(outFile, "utf8");
  return { ok: true, size: statSync(outFile).size, time, hist: histogramOf(src) };
}

function benchFixture(f: Fixture): BenchResult {
  const dir = mkdtempSync(join(tmpdir(), `zts-minify-${f.name}-`));
  // entry는 benchmark dir 안에 생성 — 여기가 npm 패키지를 resolve할 수 있는 유일한 경로
  // (tmpdir에서는 `import 'effect'` 같은 node_modules 참조가 실패). smoke.ts도 같은 이유로 동일 패턴.
  const entryFile = join(__dirname, `_minify_entry_${f.name}.ts`);
  writeFileSync(entryFile, f.entry);
  const platform = f.platform ?? "node";
  const format = f.format ?? "esm";

  try {
    const ztsOut = join(dir, "zts.js");
    const esOut = join(dir, "es.js");
    const rdOut = join(dir, "rd.js");

    const zts = runTool(
      "zts",
      ZTS_BIN,
      [
        "--bundle",
        entryFile,
        "-o",
        ztsOut,
        "--minify",
        `--platform=${platform}`,
        ...(format === "cjs" ? ["--format=cjs"] : []),
      ],
      ztsOut,
    );

    const esb = existsSync(ESBUILD_BIN)
      ? runTool(
          "esbuild",
          ESBUILD_BIN,
          [
            entryFile,
            "--bundle",
            `--outfile=${esOut}`,
            "--minify",
            "--loader:.ts=ts",
            `--platform=${platform}`,
            `--format=${format}`,
          ],
          esOut,
          __dirname,
        )
      : null;

    const rd = existsSync(ROLLDOWN_BIN)
      ? runTool(
          "rolldown",
          ROLLDOWN_BIN,
          [entryFile, "-o", rdOut, "--format", format, "--platform", platform, "--minify"],
          rdOut,
          __dirname,
        )
      : null;

    return { name: f.name, zts, esbuild: esb, rolldown: rd };
  } finally {
    rmSync(dir, { recursive: true, force: true });
    try {
      rmSync(entryFile);
    } catch {}
  }
}

function formatKb(n: number): string {
  if (n === 0) return "   -  ";
  return (n / 1024).toFixed(1).padStart(5) + "KB";
}

function pad(s: string | number, n: number): string {
  return String(s).padEnd(n);
}

function formatResult(res: BenchResult): string {
  const header =
    `\n## ${res.name}\n\n` +
    `| Tool     | Size     | Time    | 1-ch | 2-ch | 3-ch | 4-ch | 5+-ch | Total |\n` +
    `|----------|----------|---------|------|------|------|------|-------|-------|`;

  const row = (label: string, r: ToolResult | null): string => {
    if (!r)
      return `| ${pad(label, 8)} | n/a      | n/a     | -    | -    | -    | -    | -     | -     |`;
    if (!r.ok) {
      return `| ${pad(label, 8)} | FAIL     | ${pad(r.time + "ms", 7)} | -    | -    | -    | -    | -     | -     |`;
    }
    const h = r.hist;
    return `| ${pad(label, 8)} | ${formatKb(r.size)} | ${pad(r.time + "ms", 7)} | ${pad(h.len1, 4)} | ${pad(h.len2, 4)} | ${pad(h.len3, 4)} | ${pad(h.len4, 4)} | ${pad(h.len5plus, 5)} | ${pad(histTotal(h), 5)} |`;
  };

  return [
    header,
    row("zts", res.zts),
    row("esbuild", res.esbuild),
    row("rolldown", res.rolldown),
  ].join("\n");
}

function main() {
  console.log("# Minify Benchmark (#1608 baseline)\n");
  console.log("`--minify` 기준 bundle 사이즈 + distinct identifier 길이 분포.");
  console.log("문자열 토큰 노이즈는 세 도구 모두에 동일하게 적용되므로 비교는 유효.\n");

  if (!existsSync(ZTS_BIN)) {
    console.error(`ZTS 바이너리 없음: ${ZTS_BIN}\n  먼저 \`zig build\`를 실행하세요.`);
    process.exit(1);
  }

  for (const f of fixtures) {
    console.log(formatResult(benchFixture(f)));
  }
  console.log();
}

main();
