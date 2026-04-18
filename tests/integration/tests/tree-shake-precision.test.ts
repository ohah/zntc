import { describe, test, expect, afterAll } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

// #1558 Phase 5 정밀도 회귀 가드: tree-shake 후 특정 dead export가
// 번들에 실제로 없음을 검증. smoke size 비교는 통과하되 번들 내용이
// 팽창하는 회귀를 잡는다.
//
// size assertion이 아니라 symbol-level assertion — valibot 5.9 KB가
// 우연히 예전 142 KB로 회귀하지 않아도 dead export가 슬며시 섞이면
// 여기서 포착.

const ROOT = resolve(__dirname, "../../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
const BENCHMARK_DIR = join(ROOT, "tests/benchmark");

function bundleIn(benchmarkDir: string, entryContent: string, name: string): string {
  const entryFile = join(benchmarkDir, `_tsprec_${name}.ts`);
  const outFile = join(mkdtempSync(join(tmpdir(), "zts-tsprec-")), "out.js");
  writeFileSync(entryFile, entryContent);
  try {
    const r = spawnSync(ZTS_BIN, ["--bundle", entryFile, "-o", outFile, "--platform=node"], {
      stdio: "pipe",
      timeout: 30000,
    });
    if (r.status !== 0) {
      throw new Error(`ZTS bundle failed (${name}): ${r.stderr?.toString().slice(0, 400)}`);
    }
    return readFileSync(outFile, "utf-8");
  } finally {
    try {
      unlinkSync(entryFile);
    } catch {}
  }
}

// top-level `function <name>(` 선언이 번들에 있는지 확인.
// 문자열 리터럴, 속성 접근, 내부 helper 매칭은 회피.
function hasTopLevelFunction(bundle: string, name: string): boolean {
  const re = new RegExp(`^function\\s+${name}\\s*\\(`, "m");
  return re.test(bundle);
}

describe("#1558 Phase 5 tree-shake 정밀도", () => {
  const checkOrSkip = (pkg: string) => {
    const benchmarkNM = join(BENCHMARK_DIR, "node_modules", pkg);
    const rootNM = join(ROOT, "node_modules", pkg);
    if (!existsSync(benchmarkNM) && !existsSync(rootNM)) {
      return false;
    }
    return true;
  };

  test("valibot — v.object/string/number/parse만 쓰면 v.array/boolean/regex/email 없음", () => {
    if (!checkOrSkip("valibot")) return;
    const bundle = bundleIn(
      BENCHMARK_DIR,
      `import * as v from 'valibot';\n` +
        `const schema = v.object({ name: v.string(), age: v.number() });\n` +
        `const r = v.parse(schema, { name: 'Alice', age: 30 });\n` +
        `console.log(r.name, r.age);\n`,
      "valibot",
    );

    // used: 번들에 있어야
    expect(hasTopLevelFunction(bundle, "object")).toBe(true);
    expect(hasTopLevelFunction(bundle, "string")).toBe(true);
    expect(hasTopLevelFunction(bundle, "number")).toBe(true);
    expect(hasTopLevelFunction(bundle, "parse")).toBe(true);

    // dead: 번들에 없어야
    const deadExports = [
      "array",
      "boolean",
      "regex",
      "email",
      "url",
      "literal",
      "union",
      "intersect",
      "any",
      "never",
    ];
    for (const name of deadExports) {
      expect(hasTopLevelFunction(bundle, name), `dead export "${name}" leaked to bundle`).toBe(
        false,
      );
    }
  });

  test("svelte/store — readable만 쓰면 derived / readonly 함수 없음", () => {
    if (!checkOrSkip("svelte")) return;
    const bundle = bundleIn(
      BENCHMARK_DIR,
      `import { readable } from 'svelte/store';\n` +
        `const t = readable(0, set => { set(42); return () => {}; });\n` +
        `let v; t.subscribe(x => v = x);\n` +
        `console.log(v);\n`,
      "svelte",
    );

    // used
    expect(hasTopLevelFunction(bundle, "readable")).toBe(true);

    // dead (writable은 readable 내부 의존성이라 번들에 남을 수 있어 assertion 제외)
    expect(hasTopLevelFunction(bundle, "derived")).toBe(false);
    expect(hasTopLevelFunction(bundle, "readonly")).toBe(false);
  });

  test("lodash-es — uniq만 쓰면 groupBy / orderBy / mapValues 없음", () => {
    if (!checkOrSkip("lodash-es")) return;
    const bundle = bundleIn(
      BENCHMARK_DIR,
      `import { uniq } from 'lodash-es';\n` + `console.log(JSON.stringify(uniq([1,2,2,3])));\n`,
      "lodash",
    );

    expect(hasTopLevelFunction(bundle, "uniq")).toBe(true);

    // lodash-es는 대부분 const 선언 + default export라 function 선언 패턴 드묾.
    // 대신 top-level `const X =` 패턴으로 확인.
    const missingIdents = ["groupBy", "orderBy", "mapValues", "debounce", "throttle"];
    for (const name of missingIdents) {
      const re = new RegExp(`(^|\\n)(function|const|var|let)\\s+${name}\\b`, "m");
      expect(re.test(bundle), `dead identifier "${name}" leaked to bundle`).toBe(false);
    }
  });
});
