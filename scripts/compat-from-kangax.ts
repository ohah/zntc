#!/usr/bin/env bun
/**
 * kangax compat-table → ZTS 호환성 데이터 추출기 (초안).
 *
 * 목적:
 *   - references/compat-table/의 kangax 데이터에서 ZTS가 관리하는 feature set을
 *     읽어, src/transformer/compat.zig 엔트리를 재생성하기 위한 raw 데이터를
 *     얻는다.
 *   - 엔진 × feature × 최소 지원 버전 매핑을 JSON으로 덤프.
 *   - **자동 덮어쓰기는 하지 않음.** 결과를 수동 비교 후 compat.zig에 반영.
 *
 * 정책 (esbuild 방식):
 *   - feature의 모든 subtest가 true여야 해당 feature "지원"으로 판정
 *   - 하나라도 false/누락이면 unsupported
 *
 * 출력: scripts/out/compat-kangax.json
 *
 * 사용:
 *   bun run scripts/compat-from-kangax.ts [feature]
 *   bun run scripts/compat-from-kangax.ts async_await    # 특정 feature 드릴다운
 *
 * 제한:
 *   - 현재는 async/await, generator, hashbang 등 대표 샘플만 매핑.
 *   - 전체 feature 매핑은 ZTS Feature enum과 kangax feature name 사이의
 *     매핑 테이블을 추가로 채워야 한다.
 */

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const ROOT = resolve(__dirname, "..");
const KANGAX_DIR = join(ROOT, "references/compat-table");

if (!existsSync(KANGAX_DIR)) {
  console.error(`kangax clone not found: ${KANGAX_DIR}`);
  console.error(`  git clone https://github.com/compat-table/compat-table.git ${KANGAX_DIR}`);
  process.exit(1);
}

// kangax 데이터 파일은 CommonJS 모듈로 module.exports = { tests: [...] } 형식.
// require()로 그대로 로드 가능.
/* eslint-disable @typescript-eslint/no-require-imports */
const es6 = require(join(KANGAX_DIR, "data-es6.js"));
const es2016plus = require(join(KANGAX_DIR, "data-es2016plus.js"));
const esnext = require(join(KANGAX_DIR, "data-esnext.js"));

type Test = {
  name: string;
  subtests?: Test[];
  res?: Record<string, boolean | object>;
};

type Dataset = { tests: Test[] };

const ALL: Dataset[] = [es6, es2016plus, esnext];

// ZTS의 Feature enum (src/transformer/compat.zig) → kangax 테스트 이름 매핑.
// 핵심 샘플만 포함. 전체 커버를 위해선 이 맵을 확장.
const FEATURE_MAP: Record<string, string[]> = {
  async_await: ["async functions"],
  generator: ["generators"],
  arrow: ["arrow functions"],
  class: ["class"],
  destructuring: ["destructuring, declarations", "destructuring, assignment"],
  default_params: ["default function parameters"],
  spread: ["spread (...) operator"],
  for_of: ["for..of loops"],
  template_literal: ["template literals"],
  exponentiation: ["exponentiation (**) operator"],
  object_spread: ["object rest/spread properties"],
  optional_catch_binding: ["optional catch binding"],
  nullish_coalescing: ["nullish coalescing operator (??)"],
  optional_chaining: ["optional chaining operator (?.)"],
  logical_assignment: ["Logical Assignment"],
  class_static_block: ["Class static initialization blocks"],
  class_private_method: ["private class methods"],
  class_private_field: ["instance class fields"],
  hashbang: ["Hashbang Grammar"],
};

// 우리가 관심 있는 엔진만 추출 (kangax env 키 기준).
// 하나의 엔진이 여러 버전 포인트를 가지므로 최소 지원 버전을 취함.
const ENGINE_PREFIXES = {
  chrome: /^chrome(\d+)$/,
  firefox: /^firefox(\d+)$/,
  safari: /^safari(\d+(_\d+)*)/,
  edge: /^edge(\d+)$/,
  node: /^node(\d+(_\d+)*)$/,
  deno: /^deno(\d+(_\d+)*)$/,
  ios: /^ios(\d+(_\d+)*)$/,
  hermes: /^hermes(\d+_\d+_\d+)$/,
};

type Engine = keyof typeof ENGINE_PREFIXES;

/** kangax 버전 문자열 "0_12_0" → [0, 12, 0]. */
function parseVer(v: string): number[] {
  return v.split("_").map((n) => parseInt(n, 10));
}

/** a >= b. */
function verGte(a: number[], b: number[]): boolean {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const av = a[i] ?? 0;
    const bv = b[i] ?? 0;
    if (av > bv) return true;
    if (av < bv) return false;
  }
  return true;
}

/** 모든 subtest가 이 엔진/버전에서 통과하는지 (esbuild 방식). */
function allSubtestsPass(test: Test, envKey: string): boolean {
  const subtests = test.subtests ?? [test];
  for (const sub of subtests) {
    const r = sub.res?.[envKey];
    if (r !== true) return false;
  }
  return true;
}

/** 엔진별 feature 최소 지원 버전 찾기. 지원 안 하면 null. */
function findMinSupportedVersion(test: Test, engine: Engine): number[] | null {
  const re = ENGINE_PREFIXES[engine];
  const envs: string[] = [];
  // 모든 subtest res 키에서 엔진 매칭 수집
  const subs = test.subtests ?? [test];
  const keySet = new Set<string>();
  for (const sub of subs) {
    for (const k of Object.keys(sub.res ?? {})) keySet.add(k);
  }
  for (const k of keySet) if (re.test(k)) envs.push(k);

  // 버전 오름차순 정렬
  envs.sort((a, b) => {
    const av = parseVer(a.replace(re, "$1"));
    const bv = parseVer(b.replace(re, "$1"));
    for (let i = 0; i < Math.max(av.length, bv.length); i++) {
      if ((av[i] ?? 0) !== (bv[i] ?? 0)) return (av[i] ?? 0) - (bv[i] ?? 0);
    }
    return 0;
  });

  for (const env of envs) {
    if (allSubtestsPass(test, env)) {
      return parseVer(env.replace(re, "$1"));
    }
  }
  return null;
}

/** ZTS feature key에 해당하는 kangax test 찾기. */
function findTests(names: string[]): Test[] {
  const out: Test[] = [];
  for (const ds of ALL) {
    for (const t of ds.tests) {
      if (names.includes(t.name)) out.push(t);
    }
  }
  return out;
}

type EngineVer = { engine: Engine; version: number[] };
type FeatureEntry = { feature: string; supported: EngineVer[]; matchedTests: string[] };

function buildReport(): FeatureEntry[] {
  const report: FeatureEntry[] = [];
  for (const [feature, names] of Object.entries(FEATURE_MAP)) {
    const tests = findTests(names);
    const supported: EngineVer[] = [];
    for (const engine of Object.keys(ENGINE_PREFIXES) as Engine[]) {
      // 모든 매칭 테스트에서 지원되는 최소 버전의 max (가장 늦게 지원되는 쪽)
      let worst: number[] | null = null;
      let anyMissing = false;
      for (const t of tests) {
        const v = findMinSupportedVersion(t, engine);
        if (!v) {
          anyMissing = true;
          break;
        }
        if (!worst || verGte(v, worst)) worst = v;
      }
      if (!anyMissing && worst) supported.push({ engine, version: worst });
    }
    report.push({ feature, supported, matchedTests: tests.map((t) => t.name) });
  }
  return report;
}

const targetFeature = process.argv[2];
const report = buildReport();

const outDir = join(ROOT, "scripts/out");
mkdirSync(outDir, { recursive: true });
const outPath = join(outDir, "compat-kangax.json");
writeFileSync(outPath, JSON.stringify(report, null, 2));
console.log(`Wrote ${outPath}\n`);

if (targetFeature) {
  const e = report.find((r) => r.feature === targetFeature);
  if (!e) {
    console.error(`feature not in FEATURE_MAP: ${targetFeature}`);
    process.exit(1);
  }
  console.log(`## ${e.feature}`);
  console.log(`matched tests: ${e.matchedTests.join(", ")}`);
  console.log(`supported:`);
  for (const s of e.supported) {
    console.log(`  ${s.engine} ${s.version.join(".")}`);
  }
  const notSupported = Object.keys(ENGINE_PREFIXES).filter(
    (eng) => !e.supported.find((s) => s.engine === eng),
  );
  if (notSupported.length) console.log(`unsupported (in kangax): ${notSupported.join(", ")}`);
} else {
  console.log("# Summary\n");
  for (const e of report) {
    const hermes = e.supported.find((s) => s.engine === "hermes");
    const mark = hermes ? `hermes ${hermes.version.join(".")}+` : "hermes: UNSUPPORTED";
    console.log(`${e.feature.padEnd(24)} ${mark}`);
  }
}
