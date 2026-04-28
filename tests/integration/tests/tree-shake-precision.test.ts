import { describe, test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, unlinkSync, rmSync } from "node:fs";
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

function bundleFiles(files: Record<string, string>, entry: string, name: string): string {
  const dir = mkdtempSync(join(tmpdir(), `zts-tsprec-${name}-`));
  const outFile = join(dir, "out.js");
  for (const [file, content] of Object.entries(files)) {
    writeFileSync(join(dir, file), content);
  }
  try {
    const r = spawnSync(ZTS_BIN, ["--bundle", join(dir, entry), "-o", outFile, "--platform=node"], {
      stdio: "pipe",
      timeout: 30000,
    });
    if (r.status !== 0) {
      throw new Error(`ZTS bundle failed (${name}): ${r.stderr?.toString().slice(0, 400)}`);
    }
    return readFileSync(outFile, "utf-8");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// top-level `function <name>(` 선언이 번들에 있는지 확인.
// 문자열 리터럴, 속성 접근, 내부 helper 매칭은 회피.
function hasTopLevelFunction(bundle: string, name: string): boolean {
  const re = new RegExp(`^function\\s+${name}\\s*\\(`, "m");
  return re.test(bundle);
}

function runBundleSource(bundle: string): string {
  const r = spawnSync(process.execPath, ["-e", bundle], {
    stdio: "pipe",
    timeout: 30000,
  });
  if (r.status !== 0) {
    throw new Error(`node run failed: ${r.stderr?.toString().slice(0, 400)}`);
  }
  return r.stdout.toString();
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

describe("CJS static export fact 기반 DCE", () => {
  const checkOrSkip = (pkg: string) => {
    const benchmarkNM = join(BENCHMARK_DIR, "node_modules", pkg);
    const rootNM = join(ROOT, "node_modules", pkg);
    return existsSync(benchmarkNM) || existsSync(rootNM);
  };

  test("safe-buffer — Buffer named import는 구형 Node fallback body를 끌고 오지 않음", () => {
    if (!checkOrSkip("safe-buffer")) return;
    const bundle = bundleIn(
      BENCHMARK_DIR,
      `import { Buffer } from "safe-buffer";\n` +
        `console.log(Buffer.alloc(4).length === 4 ? "MATCH" : "MISS");\n`,
      "safe-buffer-cjs-static-export",
    );

    expect(runBundleSource(bundle)).toContain("MATCH");
    expect(bundle).toMatch(/\bmodule\.exports\s*=\s*buffer\b/);
    expect(bundle).not.toMatch(/\bexports\.Buffer\s*=/);
    expect(bundle).not.toMatch(/\bmodule\.exports\.Buffer\s*=/);
    expect(bundle).not.toMatch(/\bexports\.(?:alloc|allocUnsafe|allocUnsafeSlow|from)\s*=/);
    expect(bundle).not.toMatch(/function\s+SafeBuffer\s*\(/);
    expect(bundle).not.toContain("Argument must not be a number");
    expect(bundle).not.toContain("allocUnsafeSlow");
  });

  test("cookie — serialize named import는 parse 계열 body를 끌고 오지 않음", () => {
    if (!checkOrSkip("cookie")) return;
    const bundle = bundleIn(
      BENCHMARK_DIR,
      `import { serialize } from "cookie";\n` +
        `const out = serialize("session", "abc");\n` +
        `console.log(out.includes("session=abc") ? "MATCH" : "MISS");\n`,
      "cookie-cjs-static-export",
    );

    expect(runBundleSource(bundle)).toContain("MATCH");
    expect(bundle).not.toContain("argument str must be a string");
    expect(bundle).not.toMatch(/function\s+parse\s*\(/);
    expect(bundle).not.toMatch(/\bexports\.(?:parse|parseCookie|parseSetCookie)\s*=/);
    expect(bundle).not.toMatch(/\bmodule\.exports\.(?:parse|parseCookie|parseSetCookie)\s*=/);
  });

  test("path-to-regexp — match named import는 compile/stringify 계열 body를 끌고 오지 않음", () => {
    if (!checkOrSkip("path-to-regexp")) return;
    const bundle = bundleIn(
      BENCHMARK_DIR,
      `import { match } from "path-to-regexp";\n` +
        `const fn = match("/user/:id");\n` +
        `console.log(fn("/user/42")?.params.id === "42" ? "MATCH" : "MISS");\n`,
      "path-to-regexp-cjs-static-export",
    );

    expect(runBundleSource(bundle)).toContain("MATCH");
    expect(bundle).not.toMatch(/function\s+compile\s*\(/);
    expect(bundle).not.toMatch(/function\s+stringify\s*\(/);
  });
});

describe("#1665 class-level tree-shake 정밀도", () => {
  test("unused class expression with pure static field is dropped", () => {
    const bundle = bundleFiles(
      {
        "index.ts": `import { Used } from "./lib";\nconsole.log(new Used().value());\n`,
        "lib.ts":
          `export const Used = class { value() { return "used"; } };\n` +
          `const Unused = class { value() { return "unused-class-marker-1665"; } static tag = "pure"; };\n` +
          `export { Unused };\n`,
      },
      "index.ts",
      "class-expression",
    );

    expect(bundle).toContain("used");
    expect(bundle).not.toContain("unused-class-marker-1665");
  });

  test("class expression with impure static field is preserved", () => {
    const bundle = bundleFiles(
      {
        "index.ts": `import "./lib";\nconsole.log("entry");\n`,
        "lib.ts":
          `function init() { console.log("class-static-effect-1665"); return 1; }\n` +
          `const X = class { static value = init(); };\n`,
      },
      "index.ts",
      "class-expression-impure",
    );

    expect(bundle).toContain("class-static-effect-1665");
  });
});
