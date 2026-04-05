#!/usr/bin/env bun
/**
 * ZTS 트랜스파일 적합성 테스트
 *
 * esbuild ts_parser_test.go + SWC fixtures에서 추출한 테스트 케이스로
 * ZTS의 TS→JS 트랜스파일 정확도를 측정한다.
 *
 * 비교 기준: esbuild 출력 (expected)과 ZTS 출력이 일치하는지.
 * 공백/줄바꿈 차이는 정규화하여 비교.
 */

import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync, rmSync, readdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
const TEST_GO = resolve(ROOT, "references/esbuild/internal/js_parser/ts_parser_test.go");
const SWC_FIXTURE_DIR = resolve(
  ROOT,
  "references/swc/crates/swc_ecma_transforms_typescript/tests/fixture",
);

// ============================================================
// 1. esbuild 테스트 케이스 추출
// ============================================================

interface TestCase {
  source: "esbuild" | "swc";
  category: string;
  input: string;
  expected: string;
  id: string;
}

function extractEsbuildCases(): TestCase[] {
  const source = readFileSync(TEST_GO, "utf-8");
  const cases: TestCase[] = [];
  const lines = source.split("\n");

  // 추출 대상 함수 (기본 TS→JS만, mangle/target 제외)
  const targetFns = [
    "expectPrintedTS",
    "expectPrintedTSX",
    "expectPrintedExperimentalDecoratorTS",
    "expectPrintedAssignSemanticsTS",
  ];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    for (const fn of targetFns) {
      const idx = line.indexOf(`${fn}(t, `);
      if (idx === -1) continue;

      let chunk = "";
      let j = i;
      let parenDepth = 0;
      let started = false;

      outer: for (; j < lines.length && j < i + 100; j++) {
        const l = lines[j];
        for (let k = j === i ? idx : 0; k < l.length; k++) {
          const ch = l[k];
          if (ch === "(") {
            parenDepth++;
            started = true;
          }
          if (ch === ")") {
            parenDepth--;
            if (started && parenDepth === 0) {
              chunk += l.slice(0, k + 1);
              break outer;
            }
          }
        }
        chunk += (j === i ? l.slice(idx) : l) + "\n";
      }

      const afterT = chunk.slice(chunk.indexOf("(t, ") + 4);
      const args = extractTwoStringArgs(afterT);
      if (args) {
        cases.push({
          source: "esbuild",
          category: fn.replace("expectPrinted", ""),
          input: args[0],
          expected: args[1],
          id: `esbuild:${fn}:L${i + 1}`,
        });
      }
    }
  }
  return cases;
}

function extractTwoStringArgs(s: string): [string, string] | null {
  const first = extractGoString(s);
  if (!first) return null;
  let rest = s.slice(first.end).trimStart();
  if (!rest.startsWith(",")) return null;
  rest = rest.slice(1).trimStart();
  const second = extractGoString(rest);
  if (!second) return null;
  return [first.value, second.value];
}

function extractGoString(s: string): { value: string; end: number } | null {
  s = s.trimStart();
  if (s.startsWith("`")) {
    const end = s.indexOf("`", 1);
    if (end === -1) return null;
    return { value: s.slice(1, end), end: end + 1 + (s.length - s.trimStart().length) };
  }
  if (s.startsWith('"')) {
    let result = "";
    let i = 1;
    while (i < s.length) {
      if (s[i] === "\\") {
        i++;
        if (s[i] === "n") result += "\n";
        else if (s[i] === "t") result += "\t";
        else if (s[i] === "\\") result += "\\";
        else if (s[i] === '"') result += '"';
        else if (s[i] === "'") result += "'";
        else result += "\\" + s[i];
        i++;
      } else if (s[i] === '"') {
        return { value: result, end: i + 1 + (s.length - s.trimStart().length) };
      } else {
        result += s[i];
        i++;
      }
    }
  }
  return null;
}

// ============================================================
// 2. SWC fixture 수집
// ============================================================

function extractSwcCases(): TestCase[] {
  const cases: TestCase[] = [];
  if (!existsSync(SWC_FIXTURE_DIR)) return cases;

  function walk(dir: string) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(fullPath);
      } else if (entry.name === "input.ts") {
        const outputPath = join(dirname(fullPath), "output.js");
        if (existsSync(outputPath)) {
          const input = readFileSync(fullPath, "utf-8");
          const expected = readFileSync(outputPath, "utf-8");
          const relDir = dirname(fullPath).replace(SWC_FIXTURE_DIR + "/", "");
          cases.push({
            source: "swc",
            category: "typescript",
            input,
            expected,
            id: `swc:${relDir}`,
          });
        }
      }
    }
  }
  walk(SWC_FIXTURE_DIR);
  return cases;
}

// ============================================================
// 3. ZTS 실행 + 비교
// ============================================================

function normalize(s: string): string {
  return (
    s
      .replace(/\r\n/g, "\n")
      .replace(/\t/g, "  ") // tab → 2 spaces
      // 포맷팅 차이 정규화 (ZTS: 한 줄 compact, esbuild: pretty-print)
      .replace(/\{\n\s*/g, "{") // {\n  → {
      .replace(/;\n\s*/g, ";") // ;\n  → ;
      .replace(/\n\s*\}/g, "}") //  \n} → }
      .replace(/,\n\s*/g, ",") // ,\n  → ,
      .replace(/\s+$/gm, "") // trailing whitespace
      .trim()
  );
}

function runZts(
  input: string,
  isTsx: boolean,
  category?: string,
): { ok: boolean; output: string; error: string } {
  const tmpDir = mkdtempSync(join(tmpdir(), "zts-conform-"));
  const ext = isTsx ? "input.tsx" : "input.ts";
  const inputPath = join(tmpDir, ext);
  writeFileSync(inputPath, input);

  const args = [inputPath];
  // 카테고리별 CLI 옵션 추가
  if (category === "AssignSemanticsTS") {
    args.push("--use-define-for-class-fields=false");
  }
  if (category === "ExperimentalDecoratorTS") {
    args.push("--experimental-decorators");
  }

  const result = spawnSync(ZTS_BIN, args, {
    stdio: "pipe",
    timeout: 5000,
  });

  const output = result.stdout?.toString() ?? "";
  const error = result.stderr?.toString() ?? "";
  rmSync(tmpDir, { recursive: true, force: true });

  return { ok: result.status === 0, output, error };
}

// ============================================================
// 4. 메인
// ============================================================

console.log("ZTS Transpile Conformance Test\n");

const esbuildCases = extractEsbuildCases();
const swcCases = extractSwcCases();
const allCases = [...esbuildCases, ...swcCases];

console.log(`esbuild: ${esbuildCases.length} cases`);
console.log(`SWC:     ${swcCases.length} cases`);
console.log(`Total:   ${allCases.length} cases\n`);

interface Result {
  id: string;
  source: string;
  category: string;
  status: "pass" | "fail" | "error";
  reason?: string;
}

const results: Result[] = [];
let passed = 0;
let failed = 0;
let errors = 0;

for (let i = 0; i < allCases.length; i++) {
  const c = allCases[i];
  const isTsx = c.category === "TSX";
  const { ok, output, error } = runZts(c.input, isTsx, c.category);

  // ZTS가 에러를 출력해도 exit 0으로 나올 수 있음 (에러 복구)
  const hasParseError = error.includes("error:");
  if (!ok || (hasParseError && output.trim() === "")) {
    results.push({
      id: c.id,
      source: c.source,
      category: c.category,
      status: "error",
      reason: error.slice(0, 200),
    });
    errors++;
    continue;
  }

  const normalizedExpected = normalize(c.expected);
  const normalizedOutput = normalize(output);

  if (normalizedExpected === normalizedOutput) {
    results.push({ id: c.id, source: c.source, category: c.category, status: "pass" });
    passed++;
  } else {
    results.push({
      id: c.id,
      source: c.source,
      category: c.category,
      status: "fail",
      reason: `Expected:\n${c.expected.slice(0, 100)}\nGot:\n${output.slice(0, 100)}`,
    });
    failed++;
  }

  // 진행상황 (100개마다)
  if ((i + 1) % 100 === 0) {
    process.stderr.write(`  ${i + 1}/${allCases.length}...\r`);
  }
}

// ============================================================
// 5. 결과 출력
// ============================================================

console.log(`\n### Results\n`);
console.log(`| Source | Category | Pass | Fail | Error | Total | Rate |`);
console.log(`|--------|----------|------|------|-------|-------|------|`);

const groups = new Map<string, { pass: number; fail: number; error: number }>();
for (const r of results) {
  const key = `${r.source}|${r.category}`;
  const g = groups.get(key) ?? { pass: 0, fail: 0, error: 0 };
  g[r.status]++;
  groups.set(key, g);
}

for (const [key, g] of [...groups].sort()) {
  const [source, category] = key.split("|");
  const total = g.pass + g.fail + g.error;
  const rate = ((g.pass / total) * 100).toFixed(1);
  console.log(
    `| ${source} | ${category} | ${g.pass} | ${g.fail} | ${g.error} | ${total} | ${rate}% |`,
  );
}

const total = passed + failed + errors;
const rate = ((passed / total) * 100).toFixed(1);
console.log(
  `| **Total** | | **${passed}** | **${failed}** | **${errors}** | **${total}** | **${rate}%** |`,
);

// 실패 상세 (최대 30개)
const failures = results.filter((r) => r.status === "fail").slice(0, 30);
if (failures.length > 0) {
  console.log(`\n### Failures (first ${failures.length})\n`);
  for (const f of failures) {
    console.log(`#### ${f.id}`);
    console.log("```");
    console.log(f.reason);
    console.log("```\n");
  }
}

// 실패 분류 (출력 차이 패턴)
const allFailures = results.filter((r) => r.status === "fail");
const failCategories = new Map<string, { count: number; ids: string[] }>();
for (const f of allFailures) {
  const exp = f.reason?.split("\nGot:\n")[0]?.replace("Expected:\n", "") ?? "";
  const got = f.reason?.split("\nGot:\n")[1] ?? "";
  let cat = "unknown";
  if (got.trim() === "") cat = "empty output";
  else if (exp.replace(/"/g, "'") === got.replace(/"/g, "'")) cat = "quote style only";
  else if (exp.replace(/;\n/g, "\n").trim() === got.replace(/;\n/g, "\n").trim())
    cat = "semicolon diff";
  else if (exp.includes("__decorateClass") || exp.includes("__decorateParam"))
    cat = "decorator transform";
  else if (exp.includes("((") && exp.includes(") => {")) cat = "enum/namespace IIFE";
  else if (got.includes("import ") && !exp.includes("import ")) cat = "import elision";
  else if (got.trim().length > 0 && exp.trim().length > 0) cat = "codegen diff";
  const entry = failCategories.get(cat) ?? { count: 0, ids: [] };
  entry.count++;
  if (entry.ids.length < 3) entry.ids.push(f.id);
  failCategories.set(cat, entry);
}
console.log(`\n### Failure Categories (${allFailures.length} total)\n`);
for (const [cat, { count, ids }] of [...failCategories.entries()].sort(
  (a, b) => b[1].count - a[1].count,
)) {
  console.log(`- ${count}x: ${cat} (e.g. ${ids.join(", ")})`);
}

// 에러 분류 (전체)
const allErrors = results.filter((r) => r.status === "error");
const errorCategories = new Map<string, { count: number; ids: string[] }>();
for (const e of allErrors) {
  const m = e.reason?.match(/error: (.+)/);
  const msg = m ? m[1].substring(0, 80) : "unknown";
  const cat = errorCategories.get(msg) ?? { count: 0, ids: [] };
  cat.count++;
  if (cat.ids.length < 3) cat.ids.push(e.id);
  errorCategories.set(msg, cat);
}
console.log(`\n### Error Categories (${allErrors.length} total)\n`);
for (const [msg, { count, ids }] of [...errorCategories.entries()].sort(
  (a, b) => b[1].count - a[1].count,
)) {
  console.log(`- ${count}x: ${msg} (e.g. ${ids.join(", ")})`);
}

// 에러 상세 (최대 10개)
const errs = allErrors.slice(0, 10);
if (errs.length > 0) {
  console.log(`\n### Errors (first ${errs.length})\n`);
  for (const e of errs) {
    console.log(`#### ${e.id}`);
    console.log("```");
    console.log(e.reason);
    console.log("```\n");
  }
}

process.exit(0);
