import { describe, test, expect } from "bun:test";
import { bundleAndRun, createFixture, runZts } from "./helpers";
import { join } from "node:path";
import { readFileSync } from "node:fs";

/**
 * ESM wrapper 함수 호이스팅 — `strict_execution_order` 양쪽 경로 검증.
 *
 * - false (default, platform=node/browser): 함수는 factory 밖 top-level 에 `function f(){}` 으로 유지.
 *   함수명은 함수 선언 자체가 binding 을 만들므로 별도 `var f;` 추가 금지 (중복 선언 에러).
 * - true (platform=react-native, worklet 호환): 함수는 factory 내부에 위치, `f = function(){}` 할당으로
 *   변환. top-level `var f;` 선언은 export getter 가 참조하기 위해 필요.
 *
 * 회귀: axios + supports-color 결합 bundle (@node) 에서 `var hasFlag` + `function hasFlag` 중복 선언으로
 * bun strict parse 실패 → 함수 호이스팅 경로가 var 을 중복 추가하던 것을 제거.
 */
describe("ESM function hoist 양쪽 경로", () => {
  // 다중 internal function + cross-reference — supports-color / debug 같은 패키지 패턴 모사.
  const multiFuncFixture = {
    "index.js": `
      import { supportsColor } from "pkg";
      console.log(supportsColor(16));
    `,
    "node_modules/pkg/package.json": JSON.stringify({
      name: "pkg",
      type: "module",
      main: "index.js",
    }),
    "node_modules/pkg/index.js": `
      export function hasFlag(f) { return f === "color"; }
      export function supportsColor(level) { return hasFlag("color") ? level : 0; }
    `,
  };

  test("strict=false (default) — 호이스팅된 함수 runtime 정상 (axios 회귀)", async () => {
    // 중복 var 선언이 있으면 bun strict ESM 파싱 단계에서 실패 → exitCode !== 0.
    const result = await bundleAndRun(multiFuncFixture, "index.js");
    try {
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("16");
    } finally {
      await result.cleanup();
    }
  });

  test("strict=false — 번들 출력에 함수명 중복 선언 없음 (정적 검사)", async () => {
    const { dir, cleanup } = await createFixture(multiFuncFixture);
    const outFile = join(dir, "out.js");
    try {
      const { exitCode } = await runZts(["--bundle", join(dir, "index.js"), "-o", outFile]);
      expect(exitCode).toBe(0);
      const output = readFileSync(outFile, "utf-8");
      // `function hasFlag` 는 정의된 함수 형태로 한 번만 등장해야 함 — var 와 함께 선언되면 중복.
      const fnDeclCount = (output.match(/^function hasFlag\b/gm) ?? []).length;
      expect(fnDeclCount).toBeGreaterThan(0); // 호이스팅된 함수 선언이 존재
      // top-level `var hasFlag[ ,;]` (리스트 중간 포함) 이 있으면 ESM 모드 중복 선언 에러 발생.
      const varListContainsFn = /\bvar\s+[^;=]*\bhasFlag\b[^;]*;/.test(output);
      expect(varListContainsFn).toBe(false);
    } finally {
      await cleanup();
    }
  });

  test("strict=true (platform=react-native) — factory 내부 할당 + 외부 var 정상", async () => {
    const { dir, cleanup } = await createFixture({
      ...multiFuncFixture,
      "node_modules/react-native/package.json": JSON.stringify({
        name: "react-native",
        main: "index.js",
      }),
      "node_modules/react-native/index.js": "export default {};",
      "node_modules/react-native/Libraries/Image/AssetRegistry.js":
        "module.exports = { registerAsset: function(a) { return a; }, getAssetByID: function() { return null; } };",
    });
    const outFile = join(dir, "out-rn.js");
    try {
      const { exitCode } = await runZts([
        "--bundle",
        join(dir, "index.js"),
        "-o",
        outFile,
        "--platform=react-native",
      ]);
      expect(exitCode).toBe(0);
      const output = readFileSync(outFile, "utf-8");
      // RN: factory 내부 할당 스타일 `hasFlag = function(...)` 존재
      expect(output).toMatch(/hasFlag\s*=\s*function/);
      // RN: top-level `var ... hasFlag ...` 유지 (export getter 참조용)
      expect(output).toMatch(/\bvar\s+[^;]*\bhasFlag\b/);
    } finally {
      await cleanup();
    }
  });
});
