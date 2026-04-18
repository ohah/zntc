import { describe, test, expect } from "bun:test";
import { bundleAndRun } from "./helpers";

/**
 * package.json `browser` 필드 — relative-path 키의 disable (`false`) + string remap 지원.
 *
 * 참고: rspack `tests/rspack-test/normalCases/resolving/browser-field/` 케이스 기반 (#1459 follow-up).
 * bare module 키 (e.g. `"fs": false` / `"module-a": "module-b"`) 는 현재 미지원 — 별도 follow-up.
 */
describe("package.json browser 필드", () => {
  test("replacing-file1 — `./file.js`: `./new-file.js` 파일 remap", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `import v from "pkg"; console.log(v);`,
        "node_modules/pkg/package.json": JSON.stringify({
          name: "pkg",
          main: "index.js",
          browser: { "./file.js": "./new-file.js" },
        }),
        "node_modules/pkg/index.js": `export { default } from "./file.js";`,
        "node_modules/pkg/file.js": `export default "original-file";`,
        "node_modules/pkg/new-file.js": `export default "new-file";`,
      },
      "index.ts",
    );
    try {
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("new-file");
    } finally {
      await result.cleanup();
    }
  });

  test("replacing-file4 — 중첩 디렉토리 + 확장자 없는 대체 경로", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `import v from "pkg"; console.log(v);`,
        "node_modules/pkg/package.json": JSON.stringify({
          name: "pkg",
          main: "index.js",
          browser: { "./dir/file.js": "./dir/new-file" },
        }),
        "node_modules/pkg/index.js": `export { default } from "./dir/file.js";`,
        "node_modules/pkg/dir/index.js": `export default "dir-index";`,
        "node_modules/pkg/dir/file.js": `export default "original";`,
        "node_modules/pkg/dir/new-file.js": `export default "remapped";`,
      },
      "index.ts",
    );
    try {
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("remapped");
    } finally {
      await result.cleanup();
    }
  });

  test("ignoring-module — `./file.js`: false 는 빈 모듈 (회귀)", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `import * as mod from "pkg"; console.log(JSON.stringify(mod.file));`,
        "node_modules/pkg/package.json": JSON.stringify({
          name: "pkg",
          main: "index.js",
          browser: { "./file.js": false },
        }),
        "node_modules/pkg/index.js": `export * as file from "./file.js";`,
        "node_modules/pkg/file.js": `export const x = 42;`,
      },
      "index.ts",
    );
    try {
      expect(result.exitCode).toBe(0);
      // false → 빈 모듈 — namespace import 는 빈 object (혹은 undefined-like).
      expect(result.runOutput).toMatch(/\{\}|undefined/);
    } finally {
      await result.cleanup();
    }
  });

  test("axios 유사 패턴 — 여러 remap 혼합 (deep chain)", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `import v from "pkg"; console.log(v);`,
        "node_modules/pkg/package.json": JSON.stringify({
          name: "pkg",
          type: "module",
          main: "index.js",
          browser: {
            "./lib/platform/node/index.js": "./lib/platform/browser/index.js",
            "./lib/adapters/http.js": "./lib/helpers/null.js",
          },
        }),
        "node_modules/pkg/index.js": `export { default } from "./lib/platform/node/index.js";`,
        "node_modules/pkg/lib/platform/node/index.js": `export default "node-platform";`,
        "node_modules/pkg/lib/platform/browser/index.js": `export default "browser-platform";`,
        "node_modules/pkg/lib/adapters/http.js": `export default "http-adapter";`,
        "node_modules/pkg/lib/helpers/null.js": `export default null;`,
      },
      "index.ts",
    );
    try {
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("browser-platform");
    } finally {
      await result.cleanup();
    }
  });

  // Bare module 키 (spec 2단계 — #1530).
  // rspack fixture `replacing-module1`: "wrong-module": "new-module" — 소비 시 new-module 로 remap.
  test("bare module remap — `wrong-module`: `new-module` (rspack parity)", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `import v from "consumer"; console.log(v);`,
        "node_modules/consumer/package.json": JSON.stringify({
          name: "consumer",
          main: "index.js",
          browser: { "wrong-module": "new-module" },
        }),
        "node_modules/consumer/index.js": `export { default } from "wrong-module";`,
        "node_modules/new-module/package.json": JSON.stringify({
          name: "new-module",
          main: "index.js",
        }),
        "node_modules/new-module/index.js": `export default "new-module";`,
      },
      "index.ts",
    );
    try {
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("new-module");
    } finally {
      await result.cleanup();
    }
  });

  // rspack fixture `ignoring-module`: bare key `"wrong-module": false`.
  test("bare module disable — `wrong-module`: false 는 빈 모듈", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `import * as m from "consumer"; console.log(JSON.stringify(m.mod));`,
        "node_modules/consumer/package.json": JSON.stringify({
          name: "consumer",
          main: "index.js",
          browser: { "wrong-module": false },
        }),
        "node_modules/consumer/index.js": `export * as mod from "wrong-module";`,
        "node_modules/wrong-module/package.json": JSON.stringify({
          name: "wrong-module",
          main: "index.js",
        }),
        "node_modules/wrong-module/index.js": `export const x = 99;`,
      },
      "index.ts",
    );
    try {
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toMatch(/\{\}|undefined/);
    } finally {
      await result.cleanup();
    }
  });

  // rspack fixture `recursive-module`: "new-module": "new-module" 자기 참조 — 한 번의 replace 로 종료.
  test("bare module self-remap cycle — 동일 specifier 매핑은 원본 resolve (rspack parity)", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `import v from "consumer"; console.log(v);`,
        "node_modules/consumer/package.json": JSON.stringify({
          name: "consumer",
          main: "index.js",
          browser: { "new-module": "new-module" },
        }),
        "node_modules/consumer/index.js": `export { default } from "new-module";`,
        "node_modules/new-module/package.json": JSON.stringify({
          name: "new-module",
          main: "index.js",
        }),
        "node_modules/new-module/index.js": `export default "resolved-to-self";`,
      },
      "index.ts",
    );
    try {
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("resolved-to-self");
    } finally {
      await result.cleanup();
    }
  });

  test("remap 미적용 시 원본 파일 (platform=node 또는 browser 필드 없는 키)", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `import v from "pkg"; console.log(v);`,
        "node_modules/pkg/package.json": JSON.stringify({
          name: "pkg",
          main: "index.js",
          browser: { "./file.js": "./new-file.js" },
        }),
        "node_modules/pkg/index.js": `export { default } from "./file.js";`,
        "node_modules/pkg/file.js": `export default "original";`,
        "node_modules/pkg/new-file.js": `export default "new";`,
      },
      "index.ts",
      ["--platform=node"], // node 플랫폼 — browser 필드 적용 안 됨
    );
    try {
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("original");
    } finally {
      await result.cleanup();
    }
  });
});
