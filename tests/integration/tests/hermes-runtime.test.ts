import { describe, test, expect, beforeAll } from "bun:test";
import { ZTS_BIN } from "./helpers";
import { resolve } from "node:path";
import { existsSync } from "node:fs";

/**
 * Hermes 런타임 테스트.
 * hermes-engine-cli의 hermes 바이너리로 실제 JS를 실행하여 검증.
 *
 * 검증 항목:
 * - __copyProps for-in 클로저 캡처 (Hermes는 for-let-in per-iteration binding 미지원)
 * - __toCommonJS 다중 export getter 정확성
 * - RN 번들 초기화 경로 (DOMException, Performance 등)
 */

const EXAMPLE_APP = resolve(import.meta.dir, "fixtures/rn-example-app");

// Hermes 런타임 바이너리 경로 탐색
function findHermes(): string | null {
  // 1. hermes-engine-cli (npm global)
  const globalNpm = Bun.spawnSync(["npm", "root", "-g"]);
  if (globalNpm.exitCode === 0) {
    const dir = globalNpm.stdout.toString().trim();
    const hermesDir = process.platform === "linux" ? "linux64-bin" : "osx-bin";
    const p = resolve(dir, `hermes-engine-cli/${hermesDir}/hermes`);
    if (existsSync(p)) return p;
  }
  // 2. PATH
  const which = Bun.spawnSync(["which", "hermes"]);
  if (which.exitCode === 0) return which.stdout.toString().trim();
  return null;
}

function findHermesc(): string | null {
  const hermescDir = process.platform === "linux" ? "linux64-bin" : "osx-bin";
  const p = resolve(EXAMPLE_APP, `node_modules/hermes-compiler/hermesc/${hermescDir}/hermesc`);
  return existsSync(p) ? p : null;
}

function runHermes(
  hermes: string,
  code: string,
): { stdout: string; stderr: string; exitCode: number } {
  const tmpFile = `/tmp/hermes-test-${Date.now()}.js`;
  require("fs").writeFileSync(tmpFile, code);
  const result = Bun.spawnSync([hermes, tmpFile]);
  return {
    stdout: result.stdout?.toString() ?? "",
    stderr: result.stderr?.toString() ?? "",
    exitCode: result.exitCode,
  };
}

describe("Hermes 런타임: for-in 클로저 캡처 버그 검증", () => {
  let hermes: string | null = null;

  beforeAll(() => {
    hermes = findHermes();
    if (!hermes) {
      console.log("⚠ hermes runtime not found — skipping runtime tests");
      console.log("  Install: npm install -g hermes-engine-cli");
    }
  });

  test("for (let key in obj) + closure: Hermes 버그 재현", () => {
    if (!hermes) return; // skip if no hermes
    const result = runHermes(
      hermes,
      `
      var r = {};
      var src = { a: 1, b: 2, c: 3 };
      for (let key in src) {
        Object.defineProperty(r, key, { get: () => src[key], enumerable: true });
      }
      // Hermes는 모든 getter가 마지막 key를 읽음
      print(r.a === 3 && r.b === 3 && r.c === 3 ? "BUG_CONFIRMED" : "NO_BUG");
    `,
    );
    // Hermes에서 이 버그가 존재함을 확인 (회귀 감지용)
    expect(result.stdout.trim()).toBe("BUG_CONFIRMED");
  });

  test("Object.keys().forEach 방식: Hermes에서 정상 동작", () => {
    if (!hermes) return;
    const result = runHermes(
      hermes,
      `
      var r = {};
      var src = { a: 1, b: 2, c: 3 };
      Object.keys(src).forEach(function(key) {
        Object.defineProperty(r, key, { get: () => src[key], enumerable: true });
      });
      print(r.a === 1 && r.b === 2 && r.c === 3 ? "OK" : "FAIL");
    `,
    );
    expect(result.stdout.trim()).toBe("OK");
  });

  test("__copyProps 런타임: 다중 export getter 정확성", () => {
    if (!hermes) return;
    const result = runHermes(
      hermes,
      `
      var __defProp = Object.defineProperty;
      var __getOwnPropNames = Object.getOwnPropertyNames;
      var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
      var __hasOwn = Object.prototype.hasOwnProperty;
      var __copyProps = function(to, from, except, desc) {
        if (from && typeof from === "object" || typeof from === "function") {
          for (var keys = __getOwnPropNames(from), i = 0, n = keys.length, key; i < n; i++) {
            key = keys[i];
            if (!__hasOwn.call(to, key) && key !== except)
              __defProp(to, key, { get: (function(k) { return from[k]; }).bind(null, key), enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
          }
        }
        return to;
      };

      var exports_mod = {};
      __defProp(exports_mod, "default", { get: function() { return "IMPL"; }, enumerable: true });
      __defProp(exports_mod, "PublicGuard", { get: function() { return "GUARD"; }, enumerable: true });

      var result = __copyProps({ __esModule: true }, exports_mod);
      print("default:" + result.default);
      print("guard:" + result.PublicGuard);
      print(result.default === "IMPL" && result.PublicGuard === "GUARD" ? "OK" : "FAIL");
    `,
    );
    expect(result.stdout).toContain("OK");
    expect(result.stdout).toContain("default:IMPL");
    expect(result.stdout).toContain("guard:GUARD");
  });
});

describe("Hermes 런타임: ZTS 번들 실행 검증", () => {
  let hermes: string | null = null;

  beforeAll(() => {
    hermes = findHermes();
  });

  test("RN 번들 Hermes 구문 검증 (hermesc)", async () => {
    const hermesc = findHermesc();
    if (!hermesc) return; // hermesc not found (bun install 미실행)
    const outFile = resolve(EXAMPLE_APP, "zts-hermes.js");
    const zts = Bun.spawnSync([
      ZTS_BIN,
      "--bundle",
      resolve(EXAMPLE_APP, "index.js"),
      "--platform=react-native",
      "--rn-platform=ios",
      "--flow",
      "-o",
      outFile,
    ]);
    if (zts.exitCode !== 0) return; // 번들 실패 시 skip (node_modules 부재 등)

    const hbc = resolve(EXAMPLE_APP, "zts-hermes.hbc");
    const result = Bun.spawnSync([hermesc, "-emit-binary", "-out", hbc, outFile]);
    const stderr = result.stderr?.toString() ?? "";
    const errorCount = (stderr.match(/error:/g) || []).length;
    console.log(`hermesc errors: ${errorCount}`);
    expect(errorCount).toBe(0);
  }, 60_000);

  test("async method this binding via __generator(thisArg, ...) (#1909)", () => {
    if (!hermes) return;
    // ZTS 가 emit 한 ES5 generator state machine 의 callback 안 `this` 가 enclosing
    // function 의 this 와 동일해야. 이전엔 `body.call(null, _)` 라 callback 안 `this.x`
    // 가 null → throw. fix 후 `__generator(this, ...)` signature + `body.call(thisArg, _)`.
    const tmp = `/tmp/zts-async-this-${Date.now()}.js`;
    const ts = `var obj = { x: 42, async f() { return this.x * 2; } };
obj.f().then(function(v) { print("RES:" + v); }, function(e) { print("ERR:" + e.message); });`;
    require("fs").writeFileSync(tmp + ".ts", ts);
    const zts = Bun.spawnSync([ZTS_BIN, tmp + ".ts", "--target=es5", "-o", tmp]);
    expect(zts.exitCode).toBe(0);
    const result = Bun.spawnSync([hermes!, tmp]);
    expect(result.stdout?.toString() ?? "").toContain("RES:84");
  });

  test("yield* string iterable wrap via __values (#1910)", () => {
    if (!hermes) return;
    // `yield* 'abc'` 가 raw string 으로 op[5] 에 못 가도록 __values() wrap.
    const tmp = `/tmp/zts-yield-star-${Date.now()}.js`;
    const ts = `function* g() { yield* "abc"; }
var arr = [];
for (var v of g()) arr.push(v);
print("RES:" + arr.join(","));`;
    require("fs").writeFileSync(tmp + ".ts", ts);
    const zts = Bun.spawnSync([ZTS_BIN, tmp + ".ts", "--target=es5", "-o", tmp]);
    expect(zts.exitCode).toBe(0);
    const result = Bun.spawnSync([hermes!, tmp]);
    expect(result.stdout?.toString() ?? "").toContain("RES:a,b,c");
  });

  test("compound `+=` with await preserves operator (#1896)", () => {
    if (!hermes) return;
    // sum += await x() 가 sum = _state.sent() 으로 떨어지지 않아야.
    const tmp = `/tmp/zts-compound-await-${Date.now()}.js`;
    const ts = `(async function() {
  var sum = 0;
  for (var i = 0; i < 3; i++) sum += await Promise.resolve(i + 1);
  return sum;
})().then(function(v) { print("RES:" + v); });`;
    require("fs").writeFileSync(tmp + ".ts", ts);
    const zts = Bun.spawnSync([ZTS_BIN, tmp + ".ts", "--target=es5", "-o", tmp]);
    expect(zts.exitCode).toBe(0);
    const result = Bun.spawnSync([hermes!, tmp]);
    expect(result.stdout?.toString() ?? "").toContain("RES:6");
  });

  // Hermes vanilla 가 `Symbol.asyncIterator` 미지원 — RN production 은 init script 가 polyfill
  // 하지만 standalone Hermes 는 그대로 throw. RN-like 환경 시뮬용 polyfill prepend.
  const ASYNC_ITER_POLYFILL = `if (typeof Symbol !== "undefined" && !Symbol.asyncIterator) Symbol.asyncIterator = Symbol("Symbol.asyncIterator");\n`;

  test("for-await-of var hoist (#1901)", () => {
    if (!hermes) return;
    // `for await (var v of arr)` 의 `var v` + helper temps 모두 함수 top hoist.
    const tmp = `/tmp/zts-forawait-${Date.now()}.js`;
    const ts = `${ASYNC_ITER_POLYFILL}(async function() {
  var arr = [Promise.resolve(1), Promise.resolve(2), Promise.resolve(3)];
  var sum = 0;
  for await (var v of arr) sum += v;
  return sum;
})().then(function(v) { print("RES:" + v); }, function(e) { print("ERR:" + e.message); });`;
    require("fs").writeFileSync(tmp + ".ts", ts);
    const zts = Bun.spawnSync([ZTS_BIN, tmp + ".ts", "--target=es5", "-o", tmp]);
    expect(zts.exitCode).toBe(0);
    const result = Bun.spawnSync([hermes!, tmp]);
    expect(result.stdout?.toString() ?? "").toContain("RES:6");
  });

  test("async generator (async function*) yields via __asyncGenerator (#1911)", () => {
    if (!hermes) return;
    // for await of 가 async generator 의 Symbol.asyncIterator 사용 — Promise unwrap.
    const tmp = `/tmp/zts-asyncgen-${Date.now()}.js`;
    const ts = `${ASYNC_ITER_POLYFILL}async function* g() { yield 1; await Promise.resolve(); yield 2; yield 3; }
(async function() {
  var arr = [];
  for await (var v of g()) arr.push(v);
  print("RES:" + arr.join(","));
})();`;
    require("fs").writeFileSync(tmp + ".ts", ts);
    const zts = Bun.spawnSync([ZTS_BIN, tmp + ".ts", "--target=es5", "-o", tmp]);
    expect(zts.exitCode).toBe(0);
    const result = Bun.spawnSync([hermes!, tmp]);
    expect(result.stdout?.toString() ?? "").toContain("RES:1,2,3");
  });

  test("if-await self-loop fix (#1887)", () => {
    if (!hermes) return;
    // `if (cond) { await x(); }` 가 마지막 statement 인 패턴 — 이전엔 무한 루프 → 통과 = 정상 종료.
    const tmp = `/tmp/zts-ifawait-${Date.now()}.js`;
    const ts = `(async function f(x) { if (x) { await Promise.resolve(); } return "done"; })(true)
  .then(function(v) { print("RES:" + v); });`;
    require("fs").writeFileSync(tmp + ".ts", ts);
    const zts = Bun.spawnSync([ZTS_BIN, tmp + ".ts", "--target=es5", "-o", tmp]);
    expect(zts.exitCode).toBe(0);
    // 무한 루프면 timeout — 5 초 cap.
    const result = Bun.spawnSync([hermes!, tmp], { timeout: 5000 });
    expect(result.stdout?.toString() ?? "").toContain("RES:done");
  });

  test("__copyProps getOwnPropertyNames 패턴이 번들에 포함됨", async () => {
    // 이전 테스트(hermesc)에 의존하지 않고 자체 번들 생성
    const outFile = resolve(EXAMPLE_APP, "zts-hermes.js");
    const zts = Bun.spawnSync([
      ZTS_BIN,
      "--bundle",
      resolve(EXAMPLE_APP, "index.js"),
      "--platform=react-native",
      "--rn-platform=ios",
      "--flow",
      "-o",
      outFile,
    ]);
    if (zts.exitCode !== 0) return; // 번들 실패 시 skip (bun install 미실행 등)
    const output = await Bun.file(outFile).text();
    // getOwnPropertyNames + for 루프 방식 (Rolldown 호환)
    expect(output).toContain("getOwnPropertyNames");
    expect(output).toContain("getOwnPropertyDescriptor");
    // 구 방식이 남아있지 않은지 확인
    expect(output).not.toContain("Object.keys(from).forEach");
    expect(output).not.toContain("for(let key in from)");
    expect(output).not.toMatch(/for\s*\(\s*let\s+key\s+in\s+from\s*\)/);
  });
});
