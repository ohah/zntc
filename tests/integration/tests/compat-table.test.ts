/**
 * kangax/compat-table ES 다운레벨링 검증.
 *
 * 사전 준비: node tests/compat-table-extract.cjs > tests/fixtures/compat-table-tests.json
 *
 * ES5~ES2022 각 타겟별로 구문 변환 대상 feature의 exec 코드를
 * ZTS로 트랜스파일 후 실행하여 검증.
 */
import { describe, test, expect } from "bun:test";
import { resolve, join } from "node:path";
import { writeFile, mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { spawn } from "bun";

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");
const ZTS_BIN = join(PROJECT_ROOT, "zig-out/bin/zts");

// compat-table 전용 헬퍼 (테스트 코드에서 참조하는 전역 함수)
const COMPAT_HELPERS = `
var global = globalThis;
global.__createIterableObject = function(arr, methods) {
  methods = methods || {};
  if (typeof Symbol !== 'function' || !Symbol.iterator) return {};
  arr.length++;
  var iterator = {
    next: function() { return { value: arr.shift(), done: arr.length <= 0 }; },
    'return': methods['return'],
    'throw': methods['throw']
  };
  var iterable = {};
  iterable[Symbol.iterator] = function() { return iterator; };
  return iterable;
};
`;

// --- 테스트 데이터 로드 (Node에서 미리 추출한 JSON) ---
interface SubTest {
  name: string;
  code: string;
}
interface Feature {
  name: string;
  subtests: SubTest[];
}
interface TestData {
  es6: Feature[];
  es2016: Feature[];
}

const testData: TestData = require("../tests/fixtures/compat-table-tests.json");

// --- 런타임 polyfill 필요 feature (트랜스파일 불가, 스킵) ---
const RUNTIME_FEATURES = new Set([
  "proper tail calls (tail call optimisation)",
  "typed arrays",
  "Map",
  "Set",
  "WeakMap",
  "WeakSet",
  "Proxy",
  "Reflect",
  "Promise",
  "Symbol",
  "well-known symbols",
  "Object static methods",
  "String static methods",
  "String.prototype methods",
  "RegExp.prototype properties",
  "Array static methods",
  "Array.prototype methods",
  "Number properties",
  "Math methods",
  "Date.prototype[Symbol.toPrimitive]",
  "Array is subclassable",
  "RegExp is subclassable",
  "Function is subclassable",
  "Promise is subclassable",
  "miscellaneous subclassables",
  "prototype of bound functions",
  "Proxy, internal 'get' calls",
  "Proxy, internal 'set' calls",
  "Proxy, internal 'defineProperty' calls",
  "Proxy, internal 'deleteProperty' calls",
  "Proxy, internal 'getOwnPropertyDescriptor' calls",
  "Proxy, internal 'ownKeys' calls",
  "Object static methods accept primitives",
  "own property order",
  "Updated identifier syntax",
  "non-strict function semantics",
  "__proto__ in object literals",
  "Object.prototype.__proto__",
  "String.prototype HTML methods",
  "RegExp.prototype.compile",
  "RegExp syntax extensions",
  "HTML-style comments",
  'RegExp "y" and "u" flags',
  "Unicode code point escapes",
  'function "name" property',
  // ES2016+ runtime
  "Array.prototype.includes",
  "Object.values/Object.entries",
  "String padding",
  "Object.getOwnPropertyDescriptors",
  "SharedArrayBuffer",
  "Atomics",
  "RegExp Lookbehind Assertions",
  "RegExp named capture groups",
  "RegExp Unicode Property Escapes",
  "s (dotAll) flag for regular expressions",
  "Promise.prototype.finally",
  "Asynchronous Iterators",
  "Symbol.prototype.description",
  "String.prototype.{trimStart,trimEnd}",
  "Object.fromEntries",
  "Array.prototype.{flat,flatMap}",
  "String.prototype.matchAll",
  "Promise.allSettled",
  "globalThis",
  "Promise.any",
  "String.prototype.replaceAll",
  "WeakRef",
  "FinalizationRegistry",
  "AggregateError",
  "Array.prototype.at",
  "Object.hasOwn",
  "Error.prototype.cause",
  "RegExp Match Indices",
  "structuredClone",
  "Array find from last",
  "Hashbang Grammar",
  "Symbols as WeakMap keys",
  "Array Grouping",
  "Promise.withResolvers",
  "Well-formed Unicode strings",
  "Resizable and growable ArrayBuffers",
  "Atomics.waitAsync",
  "RegExp v flag with set notation + properties of strings",
]);

// --- 구문 변환 대상 feature + 도입 연도 ---
const SYNTAX_FEATURES: Record<string, number> = {
  // ES2015 (ES6)
  "default function parameters": 2015,
  "rest parameters": 2015,
  "spread syntax for iterable objects": 2015,
  "object literal extensions": 2015,
  "for..of loops": 2015,
  "octal and binary literals": 2015,
  "template literals": 2015,
  "destructuring, declarations": 2015,
  "destructuring, assignment": 2015,
  "destructuring, parameters": 2015,
  "new.target": 2015,
  const: 2015,
  let: 2015,
  "block-level function declaration": 2015,
  "arrow functions": 2015,
  class: 2015,
  super: 2015,
  generators: 2015,
  miscellaneous: 2015,
  // ES2016+
  "exponentiation (**) operator": 2016,
  "object rest/spread properties": 2018,
  "optional catch binding": 2019,
  "optional chaining operator (?..)": 2020,
  "nullish coalescing operator (??)": 2020,
  "Logical Assignment": 2021,
  "Class Fields": 2022,
  "Class static fields": 2022,
  "Private class methods": 2022,
  "Private class fields": 2022,
  "Class static blocks": 2022,
  "Ergonomic brand checks for private fields": 2022,
};

function targetYear(target: string): number {
  return target === "es5" ? 2009 : parseInt(target.replace("es", ""));
}

interface Result {
  feature: string;
  subtest: string;
  passed: boolean;
  error?: string;
}

async function runTarget(target: string): Promise<Result[]> {
  const year = targetYear(target);
  const tmpDir = await mkdtemp(join(tmpdir(), `zts-compat-${target}-`));
  const results: Result[] = [];
  let counter = 0;

  const allFeatures = [...testData.es6, ...testData.es2016];

  for (const feature of allFeatures) {
    // 런타임 feature 스킵
    if (RUNTIME_FEATURES.has(feature.name)) continue;
    // 해당 타겟에서 변환 불필요한 feature 스킵
    const featureYear = SYNTAX_FEATURES[feature.name];
    if (!featureYear || year >= featureYear) continue;

    for (const sub of feature.subtests) {
      // 동기 실행 불가능한 비동기 테스트 스킵
      if (sub.code.includes("asyncTestPassed")) continue;
      // 트랜스파일러가 원천적으로 통과 불가능한 테스트 스킵 (네이티브 엔진 전용)
      // - GeneratorFunction 생성자: yield 구문은 function* 밖에서 파싱 불가
      // - __createIterableObject: compat-table 테스트 인프라 헬퍼 의존
      if (sub.code.includes(".constructor(") && sub.code.includes("yield")) continue;
      if (sub.code.includes("__createIterableObject")) continue;

      const id = `t${counter++}`;
      const inputFile = join(tmpDir, `${id}.js`);
      const outputFile = join(tmpDir, `${id}.out.js`);

      await writeFile(inputFile, `${COMPAT_HELPERS}\n(function() {\n${sub.code}\n})()`);

      const zts = spawn({
        cmd: [ZTS_BIN, inputFile, "-o", outputFile, `--target=${target}`],
        stdout: "pipe",
        stderr: "pipe",
      });

      const [, ztsStderr, ztsExit] = await Promise.all([
        new Response(zts.stdout).text(),
        new Response(zts.stderr).text(),
        zts.exited,
      ]);

      if (ztsExit !== 0) {
        results.push({
          feature: feature.name,
          subtest: sub.name,
          passed: false,
          error: `Transpile: ${ztsStderr.slice(0, 200)}`,
        });
        continue;
      }

      try {
        const transpiled = await readFile(outputFile, "utf-8");
        // 트랜스파일된 코드에 이미 헬퍼가 포함되어 있으므로 직접 실행
        new Function(transpiled)();
        results.push({ feature: feature.name, subtest: sub.name, passed: true });
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        results.push({
          feature: feature.name,
          subtest: sub.name,
          passed: false,
          error: `Runtime: ${msg?.slice(0, 200)}`,
        });
      }
    }
  }

  await rm(tmpDir, { recursive: true, force: true }).catch(() => {});
  return results;
}

function printReport(target: string, results: Result[]) {
  const byFeature = new Map<string, { passed: number; failed: number; total: number }>();
  for (const r of results) {
    if (!byFeature.has(r.feature)) byFeature.set(r.feature, { passed: 0, failed: 0, total: 0 });
    const f = byFeature.get(r.feature)!;
    f.total++;
    if (r.passed) f.passed++;
    else f.failed++;
  }

  const p = results.filter((r) => r.passed).length;
  const total = results.length;
  const rate = total > 0 ? Math.round((p / total) * 100) : 0;

  console.log(`\n  --target=${target}: ${p}/${total} (${rate}%)`);
  for (const [name, s] of [...byFeature.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
    const r = s.total > 0 ? Math.round((s.passed / s.total) * 100) : 0;
    const icon = r === 100 ? "✅" : r >= 50 ? "🔶" : "❌";
    console.log(`    ${icon} ${name}: ${s.passed}/${s.total} (${r}%)`);
  }

  return { target, passed: p, total, rate, byFeature };
}

// --- 테스트 ---
const TARGETS = [
  "es5",
  "es2015",
  "es2016",
  "es2017",
  "es2018",
  "es2019",
  "es2020",
  "es2021",
  "es2022",
];
const allReports: ReturnType<typeof printReport>[] = [];

describe("compat-table ES 다운레벨링", () => {
  for (const target of TARGETS) {
    test(`--target=${target}`, async () => {
      const results = await runTarget(target);
      if (results.length === 0) return; // 변환 대상 없는 타겟
      const report = printReport(target, results);
      allReports.push(report);

      // 실패 상세
      const failures = results.filter((r) => !r.passed);
      for (const f of failures.slice(0, 5)) {
        console.log(`    ✗ [${f.feature}] ${f.subtest}: ${f.error?.slice(0, 100)}`);
      }
      if (failures.length > 5) console.log(`    ... and ${failures.length - 5} more`);
    }, 180_000);
  }

  test("리포트 저장", async () => {
    const reportPath = join(PROJECT_ROOT, "tests/integration/compat-table-report.json");
    const report = {
      timestamp: new Date().toISOString(),
      targets: Object.fromEntries(
        allReports.map((r) => [
          r.target,
          {
            passed: r.passed,
            total: r.total,
            rate: r.rate,
            features: Object.fromEntries(r.byFeature),
          },
        ]),
      ),
    };
    await writeFile(reportPath, JSON.stringify(report, null, 2));
    console.log(`\nReport saved: ${reportPath}`);
  });
});
