#!/usr/bin/env bun
/**
 * TSC conformance audit.
 *
 * 목적: TSC `tests/cases/conformance/` 를 oracle 로 삼아 zntc 의 parser/transpile
 * 동작이 TSC 와 어디서 어긋나는지 4분면 매트릭스로 측정. 새 parser 후보 식별.
 *
 * Oracle:
 *   - 같은 basename 의 `tests/baselines/reference/<name>.errors.txt` 가 존재 +
 *     `TS1xxx` (syntax 진단) 포함 → "syntax error 기대"
 *   - errors.txt 없음 또는 TS2xxx+ (type) 만 → "수락 기대" (zntc 는 타입만 strip)
 *
 * 분류:
 *   - OK_pass:              oracle=accept   · zntc exit=0
 *   - OK_reject:            oracle=syntax   · zntc exit≠0
 *   - MISMATCH_false_reject oracle=accept   · zntc exit≠0  ← parser 회귀 후보
 *   - MISMATCH_false_accept oracle=syntax   · zntc exit=0  ← syntax laxness 후보
 *   - HANG                  zntc timeout    · 무한 루프/병리 케이스
 *
 * v1 제약: 단일 파일 fixture 만 (`// @filename:` 포함 시 skip), `.d.ts` skip.
 *
 * Output: 4분면 카운트 + mismatch 상위 N 개 (basename + 첫 에러 라인). 종료코드 0.
 */
import { readFileSync, readdirSync, statSync, existsSync, openSync, readSync, closeSync } from "node:fs";
import { join, relative, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(SCRIPT_DIR, "..");
const ZNTC = join(ROOT, "zig-out", "bin", "zntc");
const CONFORMANCE_DIR = join(ROOT, "references/typescript/tests/cases/conformance");
const BASELINE_DIR = join(ROOT, "references/typescript/tests/baselines/reference");

const FIXTURE_EXTS = new Set([".ts", ".tsx", ".cts", ".mts"]);
const MULTIFILE_DIRECTIVE = /^\/\/\s*@filename\s*:/im;
const ZNTC_TIMEOUT_MS = 5_000;
const STDERR_CAP_BYTES = 5_000;
const FIRST_ERROR_MAX_LEN = 200;
const SAMPLE_LIMIT = 30;
const DIR_RANK_LIMIT = 15;
const DEFAULT_CONCURRENCY = 16;
const HEAD_READ_BYTES = 4_096;

/// TSC 의 일부 TS18xxx 진단은 parser-level 거부 (private name 사용 제약,
/// `#constructor` 예약어 등). TS1xxx 와 동일하게 "syntax error 기대" 로 친다.
/// 나머지 TS18xxx (type/config 영역) 는 제외.
/// 출처: references/typescript/src/compiler/diagnosticMessages.json.
const TS18_SYNTAX_LEVEL_CODES: ReadonlySet<number> = new Set([
  18006, // Classes may not have a field named 'constructor'
  18007, // JSX expressions may not use the comma operator
  18009, // Private identifiers cannot be used as parameters
  18010, // An accessibility modifier cannot be used with a private identifier
  18011, // The operand of a 'delete' operator cannot be a private identifier
  18012, // '#constructor' is a reserved word
  18016, // Private identifiers are not allowed outside class bodies
  18019, // modifier cannot be used with a private identifier
  18024, // An enum member cannot be named with a private identifier
  18026, // '#!' can only be used at the start of a file
  18029, // Private identifiers are not allowed in variable declarations
  18030, // An optional chain cannot contain private identifiers
  18036, // Class decorators can't be used with static private identifier
  18037, // 'await' expression cannot be used inside a class static block
]);

/// TSC 의 일부 TS2xxx 진단도 실제로는 ECMAScript spec early-error — TSC 가
/// type-system 진단으로 격하했을 뿐, 다른 parser (esbuild/oxc) 와 ZNTC 는
/// parser-level 에서 거부한다. AssignmentTargetType 위반 + super 위치
/// 규칙 등이 해당.
const TS2_SYNTAX_LEVEL_CODES: ReadonlySet<number> = new Set([
  2335, // 'super' can only be referenced in a derived class
  2337, // Super calls are not permitted outside constructors
  2357, // Operand of increment/decrement must be a variable or a property access
  2364, // LHS of an assignment expression must be a variable or a property access
  2398, // 'constructor' cannot be used as a parameter property name
  2406, // LHS of a 'for...in' must be a variable or a property access
  2487, // LHS of a 'for...of' must be a variable or a property access
  2701, // Target of object rest assignment must be a variable or a property access
  2777, // Increment/decrement target may not be an optional property access
  2779, // LHS of an assignment expression may not be an optional property access
  // 의도적 제외: TS2300 ("Duplicate identifier") 는 JS spec early-error
  // (`let x; let x;`) 와 TS-only semantic (`type X; type X;`) 양쪽에서 발화 —
  // dual-purpose 라 syntax 로 일률 분류 불가.
]);

function isSyntaxLevelCode(code: number): boolean {
  if (code >= 1000 && code < 2000) return true;
  return TS18_SYNTAX_LEVEL_CODES.has(code) || TS2_SYNTAX_LEVEL_CODES.has(code);
}

const OUTCOMES = [
  "OK_pass",
  "OK_reject",
  "MISMATCH_false_reject",
  "MISMATCH_false_accept",
  "HANG",
] as const;
type Outcome = (typeof OUTCOMES)[number];

interface Fixture {
  path: string;
  rel: string;
  base: string;
}

interface Oracle {
  kind: "accept" | "syntax-error";
  codes: number[];
}

interface ZntcRun {
  exit: number;
  firstError: string;
  hung: boolean;
}

interface Result {
  fixture: Fixture;
  oracle: Oracle;
  zntcExit: number;
  zntcFirstError: string;
  outcome: Outcome;
}

function collectFixtures(dir: string, out: Fixture[]) {
  for (const ent of readdirSync(dir)) {
    const p = join(dir, ent);
    const st = statSync(p);
    if (st.isDirectory()) {
      collectFixtures(p, out);
      continue;
    }
    if (!st.isFile()) continue;
    const dot = ent.lastIndexOf(".");
    if (dot < 0) continue;
    if (!FIXTURE_EXTS.has(ent.slice(dot))) continue;
    if (ent.endsWith(".d.ts")) continue;
    out.push({ path: p, rel: relative(ROOT, p), base: ent.slice(0, dot) });
  }
}

function readHead(path: string, bytes: number): string {
  const fd = openSync(path, "r");
  try {
    const buf = Buffer.alloc(bytes);
    const n = readSync(fd, buf, 0, bytes, 0);
    return buf.slice(0, n).toString("utf8");
  } finally {
    closeSync(fd);
  }
}

function isMultiFileFixture(path: string): boolean {
  return MULTIFILE_DIRECTIVE.test(readHead(path, HEAD_READ_BYTES));
}

/// TSC baseline 들을 basename → 파일 경로 리스트 로 인덱싱.
/// TSC 는 compiler-option matrix 마다 별도 `<basename>(opt=val,...).errors.txt`
/// 를 생성한다 (예: `decoratorOnClassMethod3(target=es5).errors.txt`).
/// 동일 basename 의 모든 variant 를 모아 oracle 이 매트릭스 전체를 합산한다.
function indexBaselines(): Map<string, string[]> {
  const out = new Map<string, string[]>();
  const suffix = ".errors.txt";
  for (const f of readdirSync(BASELINE_DIR)) {
    if (!f.endsWith(suffix)) continue;
    const stem = f.slice(0, -suffix.length);
    const paren = stem.indexOf("(");
    const base = paren >= 0 ? stem.slice(0, paren) : stem;
    let list = out.get(base);
    if (!list) {
      list = [];
      out.set(base, list);
    }
    list.push(f);
  }
  return out;
}

function loadOracle(base: string, baselineIndex: Map<string, string[]>): Oracle {
  const files = baselineIndex.get(base);
  if (!files) return { kind: "accept", codes: [] };
  const codes = new Set<number>();
  for (const f of files) {
    const txt = readFileSync(join(BASELINE_DIR, f), "utf8");
    for (const m of txt.matchAll(/error TS(\d+)/g)) codes.add(Number(m[1]));
  }
  const sorted = [...codes].sort((a, b) => a - b);
  const hasSyntax = sorted.some(isSyntaxLevelCode);
  return { kind: hasSyntax ? "syntax-error" : "accept", codes: sorted };
}

function runZntc(fixturePath: string): Promise<ZntcRun> {
  return new Promise((res) => {
    const child = spawn(ZNTC, [fixturePath, "-o", "/dev/null"], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stderr = "";
    let settled = false;
    const settle = (run: ZntcRun) => {
      if (settled) return;
      settled = true;
      res(run);
    };
    const timer = setTimeout(() => {
      // SIGTERM 은 일부 코드 경로가 catch 할 수 있어 SIGKILL 로 강제 종료
      child.kill("SIGKILL");
      settle({ exit: -1, firstError: "TIMEOUT", hung: true });
    }, ZNTC_TIMEOUT_MS);
    child.stderr.on("data", (chunk) => {
      if (stderr.length < STDERR_CAP_BYTES) stderr += chunk.toString();
    });
    child.stdout.on("data", () => {});
    child.on("close", (code) => {
      clearTimeout(timer);
      const firstLine = stderr.split("\n").find((l) => l.trim().length > 0) ?? "";
      settle({ exit: code ?? -1, firstError: firstLine.slice(0, FIRST_ERROR_MAX_LEN), hung: false });
    });
    child.on("error", () => {
      clearTimeout(timer);
      settle({ exit: -1, firstError: "spawn-error", hung: false });
    });
  });
}

function classify(oracle: Oracle, run: ZntcRun): Outcome {
  if (run.hung) return "HANG";
  const accepted = run.exit === 0;
  if (oracle.kind === "accept") return accepted ? "OK_pass" : "MISMATCH_false_reject";
  return accepted ? "MISMATCH_false_accept" : "OK_reject";
}

async function runChunked<T, R>(items: T[], concurrency: number, fn: (x: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: concurrency }, async () => {
    while (true) {
      const idx = next++;
      if (idx >= items.length) return;
      out[idx] = await fn(items[idx]);
    }
  });
  await Promise.all(workers);
  return out;
}

function topDir(rel: string): string {
  const parts = rel.split("/");
  const i = parts.indexOf("conformance");
  return i >= 0 && i + 1 < parts.length ? parts[i + 1] : "(root)";
}

function zeroCounts(): Record<Outcome, number> {
  return Object.fromEntries(OUTCOMES.map((o) => [o, 0])) as Record<Outcome, number>;
}

function summarizeByDir(results: Result[]): Map<string, Record<Outcome, number>> {
  const map = new Map<string, Record<Outcome, number>>();
  for (const r of results) {
    const dir = topDir(r.fixture.rel);
    let bucket = map.get(dir);
    if (!bucket) {
      bucket = zeroCounts();
      map.set(dir, bucket);
    }
    bucket[r.outcome]++;
  }
  return map;
}

function getArg(name: string): string | undefined {
  const prefix = `--${name}=`;
  const hit = process.argv.find((a) => a.startsWith(prefix));
  return hit ? hit.slice(prefix.length) : undefined;
}

function printSamples(label: string, results: Result[], outcome: Outcome, format: (r: Result) => string) {
  console.log(`\n--- ${label} samples (max ${SAMPLE_LIMIT}) ---`);
  const xs = results.filter((r) => r.outcome === outcome).slice(0, SAMPLE_LIMIT);
  for (const r of xs) console.log(format(r));
}

async function main() {
  if (!existsSync(ZNTC)) {
    console.error(`zntc binary not found at ${ZNTC}. Run \`zig build\` first.`);
    process.exit(2);
  }
  if (!existsSync(CONFORMANCE_DIR)) {
    console.error(`TSC conformance dir not found at ${CONFORMANCE_DIR}.`);
    process.exit(2);
  }

  const limit = Number(getArg("limit") ?? Infinity);
  const filterArg = getArg("filter");
  const filterRe = filterArg ? new RegExp(filterArg) : null;
  const concurrency = Number(getArg("concurrency") ?? DEFAULT_CONCURRENCY);
  const showMismatches = process.argv.includes("--show-mismatches");

  const allFixtures: Fixture[] = [];
  collectFixtures(CONFORMANCE_DIR, allFixtures);

  const singleFile: Fixture[] = [];
  let skippedMultifile = 0;
  for (const f of allFixtures) {
    if (isMultiFileFixture(f.path)) {
      skippedMultifile++;
      continue;
    }
    if (filterRe && !filterRe.test(f.rel)) continue;
    singleFile.push(f);
    if (singleFile.length >= limit) break;
  }

  const baselineIndex = indexBaselines();

  console.error(
    `Scanning ${singleFile.length} single-file fixtures (skipped ${skippedMultifile} multi-file, ${allFixtures.length} total). Concurrency=${concurrency}.`,
  );

  const t0 = performance.now();
  const results = await runChunked(singleFile, concurrency, async (f) => {
    const oracle = loadOracle(f.base, baselineIndex);
    const run = await runZntc(f.path);
    return {
      fixture: f,
      oracle,
      zntcExit: run.exit,
      zntcFirstError: run.firstError,
      outcome: classify(oracle, run),
    } satisfies Result;
  });
  const elapsedSec = ((performance.now() - t0) / 1000).toFixed(1);

  const counts = zeroCounts();
  for (const r of results) counts[r.outcome]++;

  const total = results.length;
  const okRate = total > 0 ? (((counts.OK_pass + counts.OK_reject) / total) * 100).toFixed(2) : "0";

  console.log("\n=== TSC Conformance Audit (single-file) ===");
  console.log(`Total fixtures:    ${total}`);
  console.log(`OK_pass:           ${counts.OK_pass}`);
  console.log(`OK_reject:         ${counts.OK_reject}`);
  console.log(`false_reject (FR): ${counts.MISMATCH_false_reject}  ← parser 회귀 후보 (P0)`);
  console.log(`false_accept (FA): ${counts.MISMATCH_false_accept}  ← syntax laxness 후보 (P1)`);
  console.log(`HANG:              ${counts.HANG}  ← parser 무한 루프 후보 (P0)`);
  console.log(`Match rate:        ${okRate}%`);
  console.log(`Elapsed:           ${elapsedSec}s  (zntc timeout per fixture: ${ZNTC_TIMEOUT_MS}ms)`);

  console.log("\n--- Top dirs by FR (false_reject) ---");
  const byDir = summarizeByDir(results);
  const dirsByFR = [...byDir.entries()].sort(
    (a, b) => b[1].MISMATCH_false_reject - a[1].MISMATCH_false_reject,
  );
  for (const [dir, c] of dirsByFR.slice(0, DIR_RANK_LIMIT)) {
    if (c.MISMATCH_false_reject === 0) break;
    const sum = OUTCOMES.reduce((s, o) => s + c[o], 0);
    console.log(`  ${dir.padEnd(30)} FR=${c.MISMATCH_false_reject}  FA=${c.MISMATCH_false_accept}  (of ${sum})`);
  }

  if (counts.HANG > 0) {
    console.log("\n--- HANG fixtures (full list) ---");
    for (const r of results.filter((r) => r.outcome === "HANG")) console.log(`  ${r.fixture.rel}`);
  }

  if (showMismatches) {
    printSamples("false_reject", results, "MISMATCH_false_reject", (r) =>
      `  ${r.fixture.rel}\n    err: ${r.zntcFirstError}`,
    );
    printSamples("false_accept", results, "MISMATCH_false_accept", (r) => {
      const codes = r.oracle.codes.filter(isSyntaxLevelCode).join(",");
      return `  ${r.fixture.rel}  TS:${codes}`;
    });
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
