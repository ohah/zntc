import { describe, test, expect } from "bun:test";
import { createFixture, ZTS_BIN } from "./helpers";
import { resolve } from "node:path";

/**
 * Regression: transformer.visitNode가 var_declaration을 복제해 원본 노드를
 * `ast.nodes`에 orphan으로 남긴 상태에서 minify.removeDeadStores가 orphan까지
 * 순회하면, orphan의 init에 포함된 identifier_reference가 공유 symbol의
 * reference_count를 중복 감산해 실제로는 사용 중인 live 선언까지 dead 판정 후
 * 제거됨.
 *
 * 실제 증상: react-devtools-core/dist/backend.js의 `var UPDATE_AGE_ON_GET =
 * Symbol('updateAgeOnGet')` 선언이 번들에서 사라져 RN이
 * `ReferenceError: Property 'UPDATE_AGE_ON_GET' doesn't exist`로 부팅 실패.
 *
 * 트리거 조건: 아래 네 개가 동시에 있는 모듈.
 *  1) arrow IIFE 래퍼 (`(() => { ... })()`)
 *  2) 그 안에 module factory도 arrow (webpack 출력 패턴)
 *  3) 어떤 symbol(S)이 module-local로 선언
 *  4) S를 쓰는 함수가 다수 존재하며, 그 중 최소 하나는 사용처가 없어
 *     dead-store 대상 (자신은 쓰이지 않지만 body에서 S 참조)
 *
 * 수정: minify가 root에서 BFS로 도달 가능한 노드 bitset을 만들고,
 * removeDeadStores가 그 bitset 밖의 var_declaration을 건드리지 않도록 함.
 */
describe("bundle: minify ignores orphan var_decls (#번개 실측)", () => {
  test("module-local symbol survives when unused helper references it", async () => {
    const fixture = await createFixture({
      "entry.js": `
        (() => {
            var __webpack_modules__ = ({
                730: ((module, _exp, __webpack_require__) => {
                    var UPDATE_AGE_ON_GET = Symbol('updateAgeOnGet');

                    var A = (function() {
                        function A(o) { o[UPDATE_AGE_ON_GET] = true; }
                        return A;
                    })();

                    var f = function f(s) { if (s[UPDATE_AGE_ON_GET]) return true; };

                    module.exports = A;
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

      // 버그 시 선언이 제거되어 사용부만 남음 → 1회.
      // 수정 후 선언 + 사용 = 최소 2회.
      const occurrences = output.split("UPDATE_AGE_ON_GET").length - 1;
      expect(occurrences).toBeGreaterThanOrEqual(2);
      expect(output).toContain('UPDATE_AGE_ON_GET = Symbol("updateAgeOnGet")');
    } finally {
      await fixture.cleanup();
    }
  });
});
