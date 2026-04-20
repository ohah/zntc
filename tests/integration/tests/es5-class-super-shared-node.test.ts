import { describe, test, expect } from "bun:test";
import { createFixture, ZTS_BIN } from "./helpers";
import { resolve } from "node:path";

/**
 * Regression: bundle + --target=es5로 `extends` + `super()` + rest param 생성자를
 * 가진 클래스를 변환할 때, class-lowering의 intermediate function_declaration이
 * orphan으로 남아 minify의 `mergeAdjacentDecls`가 공유된 `var _this;` 노드의
 * list_len을 0으로 비우고 live function body가 `var ;`로 깨지는 버그(#1710).
 *
 * 원인: `prependToFunctionBody`가 매 호출마다 새 function_declaration 노드를
 * 만들어 intermediate function을 `ast.nodes`에 orphan으로 남겼음. pass 2
 * (`lowerAllFunctionParams`)가 orphan을 포함한 모든 function_declaration에
 * rest-param stmt를 prepend하면서 orphan body에 `[var rest, var _this, ...]`
 * 인접 쌍이 생성됐고, `mergeAdjacentDecls`가 이를 merge하면서 공유된 var_this
 * 노드를 수정했음.
 *
 * 수정: `prependToFunctionBody`가 body만 in-place로 교체하도록 변경 +
 * defensive하게 `mergeAdjacentDecls`는 cur 노드를 empty_statement로 교체.
 *
 * 트리거 조건:
 * - `class Child extends Parent { field = []; constructor(...rest) { super(); ... } }`
 * - `--bundle --target=es5`
 */
describe("bundle es5: extends + super + rest param class ctor", () => {
  test("var _this declaration survives minify.mergeAdjacentDecls", async () => {
    const fixture = await createFixture({
      "gesture.ts": `
        export class Gesture {
          prepare(): void {}
        }
      `,
      "composition.ts": `
        import { Gesture } from './gesture';

        export class ComposedGesture extends Gesture {
          protected gestures: Gesture[] = [];
          protected simultaneousGestures: Gesture[] = [];
          protected requireGesturesToFail: Gesture[] = [];

          constructor(...gestures: Gesture[]) {
            super();
            this.gestures = gestures;
          }
        }
      `,
      "entry.ts": `
        import { ComposedGesture } from './composition';
        console.log(ComposedGesture);
      `,
    });

    try {
      const entry = resolve(fixture.dir, "entry.ts");
      const proc = Bun.spawnSync([ZTS_BIN, "--bundle", "--target=es5", entry]);
      expect(proc.exitCode).toBe(0);
      const output = proc.stdout.toString();

      // 버그 시 `var ;` (identifier 누락) 출력. 수정 후 `var _this;`.
      expect(output).not.toMatch(/var\s*;/);
      expect(output).toContain("var _this;");

      // 생성자 body 안에서 _this가 선언된 뒤 대입되어야 함 (undeclared assignment 금지).
      const ctorBody = output.match(
        /function\s+ComposedGesture\s*\(\s*\)\s*\{([\s\S]*?)\n\s*\}/,
      );
      expect(ctorBody).not.toBeNull();
      expect(ctorBody![1]).toContain("var _this;");
      expect(ctorBody![1]).toContain("_this = __callSuper");
    } finally {
      await fixture.cleanup();
    }
  });
});
