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

function findHermesc(): string {
  const hermescDir = process.platform === "linux" ? "linux64-bin" : "osx-bin";
  return resolve(EXAMPLE_APP, `node_modules/hermes-compiler/hermesc/${hermescDir}/hermesc`);
}

function runHermes(
  hermes: string,
  code: string,
): { stdout: string; stderr: string; exitCode: number } {
  const tmpFile = `/tmp/hermes-test-${Date.now()}.js`;
  Bun.spawnSync(["bash", "-c", `cat > ${tmpFile} << 'HERMES_EOF'\n${code}\nHERMES_EOF`]);
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
      var __hasOwn = Object.prototype.hasOwnProperty;
      var __copyProps = (to, from) => { Object.keys(from).forEach(key => { if (!__hasOwn.call(to, key)) __defProp(to, key, { get: () => from[key], enumerable: true }); }); return to; };

      var exports_mod = {};
      __defProp(exports_mod, "default", { get: () => "IMPL", enumerable: true });
      __defProp(exports_mod, "PublicGuard", { get: () => "GUARD", enumerable: true });

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
    expect(zts.exitCode).toBe(0);

    const hbc = resolve(EXAMPLE_APP, "zts-hermes.hbc");
    const result = Bun.spawnSync([hermesc, "-emit-binary", "-out", hbc, outFile]);
    const stderr = result.stderr?.toString() ?? "";
    const errorCount = (stderr.match(/error:/g) || []).length;
    console.log(`hermesc errors: ${errorCount}`);
    expect(errorCount).toBe(0);
  }, 60_000);

  test("__copyProps forEach 패턴이 번들에 포함됨", async () => {
    const outFile = resolve(EXAMPLE_APP, "zts-hermes.js");
    const output = await Bun.file(outFile).text();
    // forEach 방식이 사용되는지 확인
    expect(output).toContain("Object.keys(from).forEach");
    // 구 방식 (for-let-in)이 남아있지 않은지 확인
    expect(output).not.toContain("for(let key in from)");
    expect(output).not.toMatch(/for\s*\(\s*let\s+key\s+in\s+from\s*\)/);
  });
});
