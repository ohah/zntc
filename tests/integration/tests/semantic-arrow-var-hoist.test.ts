import { describe, test, expect } from "bun:test";
import { createFixture, ZTS_BIN } from "./helpers";
import { resolve } from "node:path";

/**
 * Regression: arrow function body 의 `var` / `function` 선언이 semantic analyzer 의
 * function-scope hoisting 을 받지 못해, 같은 arrow body 안에서 선언 위치보다 앞에 있는
 * 다른 함수가 참조하면 resolve 실패 → `reference_count == 0` → minify dead-store 가
 * 선언을 통째로 `empty_statement` 로 교체. 번들 런타임에 undeclared identifier 참조로
 * 크래시.
 *
 * 실제 증상: `react-devtools-core/dist/backend.js` 의 `compare-versions` 모듈이
 * webpack arrow factory 안에서
 *   `var compareVersions = function (v1, v2) { var n1 = validateAndParse(v1); ... };`
 *   ...
 *   `var validateAndParse = function (v) { ... };`
 * 패턴을 씀. bundle 에서 `var validateAndParse` 선언이 사라져 RN 이
 * `ReferenceError: Property 'validateAndParse' doesn't exist` 로 크래시.
 *
 * 원인: 일반 `function_expression` / `function_declaration` 은 `visitFunctionBodyInner`
 * 를 타며 `predeclareVarDecls` 가 함수 스코프에 var/function 을 미리 등록한다. 그러나
 * `visitArrowFunction` 은 body stmts 를 직접 `visitNodeList` 로 돌려 이 pre-pass 를
 * 건너뛰었다. UPDATE_AGE_ON_GET (#1677) / React.forwardRef (#1680) 를 고치면서 뒤에
 * 있던 이 버그가 드러났습니다.
 *
 * 수정: `visitArrowFunction` 도 block body 일 때 `predeclareVarDecls` 를 먼저 호출.
 */
describe("bundle: var/function in arrow body is hoisted for static resolution", () => {
  test("var function declared after use in arrow body survives bundle", async () => {
    const fixture = await createFixture({
      "entry.js": `
        (() => {
            var __webpack_modules__ = ({
                730: ((module, _exp, __webpack_require__) => {
                    var compareVersions = function compareVersions(v1, v2) {
                        var n1 = validateAndParse(v1);
                        return n1;
                    };

                    var validate = function validate(version) {
                        return typeof version === 'string';
                    };

                    var validateAndParse = function validateAndParse(version) {
                        return version.split('.');
                    };

                    module.exports = { compareVersions: compareVersions, validate: validate };
                })
            });
            function __webpack_require__(id) {
                var m = { exports: {} };
                __webpack_modules__[id](m, m.exports, __webpack_require__);
                return m.exports;
            }
            return __webpack_require__(730);
        })();
      `,
    });

    try {
      const entry = resolve(fixture.dir, "entry.js");
      const proc = Bun.spawnSync([
        ZTS_BIN,
        "--bundle",
        "--platform=react-native",
        "--rn-platform=ios",
        entry,
      ]);
      expect(proc.exitCode).toBe(0);
      const output = proc.stdout.toString();

      // 버그 시: 선언이 제거되어 사용부만 남음 → 1회.
      // 수정 후: 선언 + 사용 ≥ 2회.
      const occurrences = output.split("validateAndParse").length - 1;
      expect(occurrences).toBeGreaterThanOrEqual(2);
      expect(output).toMatch(/validateAndParse\s*=\s*function/);
    } finally {
      await fixture.cleanup();
    }
  });
});
