import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun, createFixture, runZts } from "./helpers";
import { join } from "node:path";
import { readFileSync } from "node:fs";

// Rolldown 호환 런타임 헬퍼 검증 — getter/non-enumerable 프로퍼티 보존, module.exports 직접 반환.
describe("런타임 헬퍼: __copyProps / __toCommonJS", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("CJS default export의 getter가 보존된다", async () => {
    // CJS module.exports에 getter를 설정 → ESM import 시 __toESM → __copyProps.
    // getter가 복사 후에도 정상 동작하는지 검증.
    const result = await bundleAndRun({
      "index.ts": `
        import mod from './lazy.js';
        console.log(mod.getVal());
      `,
      "lazy.js": `
        var _cached = null;
        module.exports = {};
        Object.defineProperty(module.exports, 'getVal', {
          get: function() {
            if (!_cached) _cached = function() { return 'lazy-ok'; };
            return _cached;
          },
          enumerable: true
        });
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("lazy-ok");
  });

  test("CJS non-enumerable export가 보존된다", async () => {
    // non-enumerable 프로퍼티도 __copyProps가 getOwnPropertyNames로 복사해야 함.
    const result = await bundleAndRun({
      "index.ts": `
        import mod from './hidden.js';
        console.log(mod.secret);
      `,
      "hidden.js": `
        module.exports = {};
        Object.defineProperty(module.exports, 'secret', {
          value: 'hidden-ok',
          enumerable: false,
          configurable: true
        });
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("hidden-ok");
  });

  test("ESM의 __toCommonJS가 CJS require로 소비될 때 live getter 동작", async () => {
    // ESM을 CJS에서 require()할 때 __toCommonJS → __esm 조합이 정상 동작.
    // let 변수의 live binding이 getter를 통해 유지되는지 검증.
    const result = await bundleAndRun({
      "index.ts": `
        const mod = require('./counter.js');
        console.log(mod.count);
        mod.increment();
        console.log(mod.count);
      `,
      "counter.js": `
        export let count = 0;
        export function increment() { count++; }
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("0\n1");
  });

  test("CJS module.exports 객체의 lazy getter가 원본 그대로 전달된다", async () => {
    // ReactNativePrivateInterface 패턴: module.exports = { get X() { return lazy(); } }
    // __toCommonJS가 module.exports를 직접 반환하면 getter가 보존됨.
    const result = await bundleAndRun({
      "index.ts": `
        import iface from './iface.js';
        console.log(iface.getA());
        console.log(iface.getB());
      `,
      "iface.js": `
        var _cachedA = null;
        var _cachedB = null;
        module.exports = {
          get getA() {
            if (!_cachedA) _cachedA = function() { return 'A-ok'; };
            return _cachedA;
          },
          get getB() {
            if (!_cachedB) _cachedB = function() { return 'B-ok'; };
            return _cachedB;
          }
        };
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("A-ok\nB-ok");
  });

  test("여러 named export의 CJS interop이 모두 정상 동작", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        import { add, PI } from './math.cjs';
        console.log(add(1, 2));
        console.log(PI);
      `,
      "math.cjs": `
        exports.add = function(a, b) { return a + b; };
        exports.PI = 3.14;
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("3\n3.14");
  });

  test("번들 출력에 getOwnPropertyNames/getOwnPropertyDescriptor가 포함된다", async () => {
    // __copyProps가 rolldown 방식의 프로퍼티 열거를 사용하는지 번들 코드로 검증.
    const { dir, cleanup: c } = await createFixture({
      "index.ts": `import mod from './cjs.js'; console.log(mod);`,
      "cjs.js": `module.exports = { x: 1 };`,
    });
    cleanup = c;

    const outFile = join(dir, "out.js");
    const bundle = await runZts(["--bundle", join(dir, "index.ts"), "-o", outFile]);
    expect(bundle.exitCode).toBe(0);

    const code = readFileSync(outFile, "utf-8");
    // __copyProps에 getOwnPropertyNames 사용
    expect(code).toContain("getOwnPropertyNames");
    expect(code).toContain("getOwnPropertyDescriptor");
    // bind로 key 고정
    expect(code).toContain(".bind(null,");
    // __toCommonJS에 module.exports 직접 반환 경로
    expect(code).toContain("module.exports");
  });
});
