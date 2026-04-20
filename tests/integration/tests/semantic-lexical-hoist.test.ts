import { describe, test, expect } from "bun:test";
import { createFixture, ZTS_BIN } from "./helpers";
import { resolve } from "node:path";

/**
 * Regression: `const`/`let` 가 선언 위치 **앞** 의 중첩 함수에서 참조될 때 semantic
 * analyzer 가 block scope 에 심볼을 등록하지 않아 reference_count 가 0 으로 남고,
 * 이어지는 minify dead-store 가 선언 자체를 empty_statement 로 날리던 버그.
 *
 * 실제 증상: `react-native/Libraries/LogBox/LogBox.js` 가 다음 패턴을 사용.
 * ```js
 * if (__DEV__) {
 *   LogBox = { install: function() { consoleWarnImpl = registerWarning; ... } };
 *   const registerWarning = (...args) => { ... };
 * }
 * ```
 * ZTS 번들에서 `var registerWarning = ...` 이 사라져 RN 부팅 시
 * `ReferenceError: Property 'registerWarning' doesn't exist` 로 크래시.
 *
 * 수정: `visitBlockStatement` 가 statement 순회 전에 block 안의 let/const/class 선언을
 * 현재 block scope 에 미리 등록한다. TDZ 는 런타임 개념이므로 정적 분석에서는 binding
 * 이 block 진입 시점부터 scope 에 존재하는 것처럼 처리해야 ECMAScript 스펙에 맞다.
 */
describe("bundle: lexical hoist for block-scoped const referenced from nested fn", () => {
  test("const declared after use inside nested function survives bundle", async () => {
    const fixture = await createFixture({
      "entry.js": `
        var LogBox;
        if (true) {
          var originalConsoleWarn = void 0;
          var consoleWarnImpl = void 0;

          LogBox = {
            install: function() {
              originalConsoleWarn = console.warn.bind(console);
              console.warn = function() {
                var args = [].slice.call(arguments, 0);
                consoleWarnImpl.apply(void 0, args);
              };
              consoleWarnImpl = registerWarning;
            }
          };

          const registerWarning = function(a, b, c) {
            originalConsoleWarn(a, b, c);
          };
        }
        module.exports = LogBox;
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
      // 수정 후: 선언 + 2 사용처 (실제로는 1 사용처만 있는 이 repro 기준 2회).
      const occurrences = output.split("registerWarning").length - 1;
      expect(occurrences).toBeGreaterThanOrEqual(2);
      expect(output).toMatch(/registerWarning\s*=\s*function/);
    } finally {
      await fixture.cleanup();
    }
  });

  test("let in block referenced before declaration from nested arrow", async () => {
    const fixture = await createFixture({
      "entry.js": `
        {
          var api = { use: () => helper() };
          let helper = function() { return 42; };
          module.exports = api;
        }
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
      expect(output.split("helper").length - 1).toBeGreaterThanOrEqual(2);
      expect(output).toMatch(/helper\s*=\s*function/);
    } finally {
      await fixture.cleanup();
    }
  });
});
