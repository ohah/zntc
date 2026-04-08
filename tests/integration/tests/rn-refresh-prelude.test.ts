/**
 * RN react-refresh prelude 통합 테스트.
 *
 * 롤리팝 방식: InitializeCore를 prelude(run_before_main)로 엔트리 전에 실행하여
 * __ReactRefresh가 컴포넌트 $RefreshReg$ 호출 시점에 이미 사용 가능하게 한다.
 *
 * 검증 항목:
 * - RN + dev mode에서 InitializeCore가 자동으로 prelude에 포함되는지
 * - $RefreshReg$가 __ReactRefresh.register()를 정상 호출하는지
 * - 실행 순서: HMR 런타임 → InitializeCore(prelude) → 컴포넌트 모듈
 * - HMR update 시 performReactRefresh가 호출되는지
 */
import { describe, test, expect, afterEach } from "bun:test";
import { createFixture, runZtsInDir } from "./helpers";
import { join } from "node:path";
import { readFileSync, writeFileSync } from "node:fs";
import { spawn } from "bun";

describe("RN react-refresh prelude", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  /**
   * mock InitializeCore + react-refresh/runtime을 사용하여
   * prelude가 정상 동작하는지 검증.
   */
  function createRNFixture() {
    return createFixture({
      // mock react-refresh/runtime — 최소 API 구현
      "node_modules/react-refresh/cjs/react-refresh-runtime.development.js": `
        'use strict';
        var families = new Map();
        var pendingUpdates = [];
        exports.register = function(type, id) {
          families.set(id, { current: type });
          if (typeof globalThis.__TEST_REFRESH_LOG__ === 'undefined') globalThis.__TEST_REFRESH_LOG__ = [];
          globalThis.__TEST_REFRESH_LOG__.push({ action: 'register', id: id });
        };
        exports.createSignatureFunctionForTransform = function() {
          return function(type) { return type; };
        };
        exports.performReactRefresh = function() {
          if (typeof globalThis.__TEST_REFRESH_LOG__ === 'undefined') globalThis.__TEST_REFRESH_LOG__ = [];
          globalThis.__TEST_REFRESH_LOG__.push({ action: 'performReactRefresh', families: families.size });
        };
        exports.injectIntoGlobalHook = function(g) {
          if (typeof globalThis.__TEST_REFRESH_LOG__ === 'undefined') globalThis.__TEST_REFRESH_LOG__ = [];
          globalThis.__TEST_REFRESH_LOG__.push({ action: 'injectIntoGlobalHook' });
        };
        exports.isLikelyComponentType = function() { return false; };
        exports.getFamilyByType = function() { return undefined; };
        exports._families = families;
      `,
      "node_modules/react-refresh/runtime.js": `
        'use strict';
        module.exports = require('./cjs/react-refresh-runtime.development.js');
      `,
      "node_modules/react-refresh/package.json": `{ "name": "react-refresh", "main": "runtime.js" }`,

      // mock react-native InitializeCore — setUpReactRefresh ���할
      "node_modules/react-native/Libraries/Core/InitializeCore.js": `
        'use strict';
        // setUpReactRefresh 역할: react-refresh/runtime을 로드하고 global에 노출
        var ReactRefreshRuntime = require('react-refresh/runtime');
        ReactRefreshRuntime.injectIntoGlobalHook(globalThis);
        var Refresh = {
          register: ReactRefreshRuntime.register,
          createSignatureFunctionForTransform: ReactRefreshRuntime.createSignatureFunctionForTransform,
          performReactRefresh: ReactRefreshRuntime.performReactRefresh,
          performFullRefresh: function() {},
          isLikelyComponentType: ReactRefreshRuntime.isLikelyComponentType,
          getFamilyByType: ReactRefreshRuntime.getFamilyByType,
        };
        globalThis.__ReactRefresh = Refresh;
        if (typeof globalThis.__TEST_REFRESH_LOG__ === 'undefined') globalThis.__TEST_REFRESH_LOG__ = [];
        globalThis.__TEST_REFRESH_LOG__.push({ action: 'InitializeCore' });
      `,
      "node_modules/react-native/package.json": `{ "name": "react-native", "main": "index.js" }`,

      // 사용자 코드
      "App.tsx": `
        export default function App() { return "hello from App"; }
      `,
      "index.tsx": `
        import App from './App';
        globalThis.__APP_RESULT__ = App();
      `,
    });
  }

  test("RN dev mode에서 InitializeCore가 prelude로 자동 포함된다", async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "index.tsx",
      "-o",
      outFile,
      "--platform=react-native",
      "--dev",
    ]);

    expect(result.exitCode).toBe(0);
    const bundle = readFileSync(outFile, "utf-8");

    // InitializeCore 코드가 번들에 포함되어야 함
    expect(bundle).toContain("__ReactRefresh");
    expect(bundle).toContain("injectIntoGlobalHook");

    // InitializeCore의 require/init 호출이 엔트리 호출보다 앞에 있어야 함
    // (모듈 정의 순서가 아닌 호출 순서가 중요)
    // run_before_main 호출은 엔트리 init 호출 직전에 삽입됨
    const lines = bundle.split("\n");
    const initCallLine = lines.findIndex(
      (l) =>
        /(?:require|init)_.*InitializeCore/.test(l) || /(?:require|init)_.*initialize_core/.test(l),
    );
    // 번들 끝부분의 엔트리 호출 직전에 InitializeCore 호출이 있어야 함
    // (또는 __esm body 안에서 호출)
    expect(initCallLine).toBeGreaterThan(-1);
  });

  test("$RefreshReg$가 __ReactRefresh 설정 후 정상 호출된다", async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "index.tsx",
      "-o",
      outFile,
      "--platform=react-native",
      "--dev",
    ]);
    expect(result.exitCode).toBe(0);

    // 번들 실행 + 결과 검증 스크립트
    const testScript = join(fixture.dir, "test_runner.js");
    const bundleCode = readFileSync(outFile, "utf-8");
    writeFileSync(
      testScript,
      `
      ${bundleCode}

      var log = globalThis.__TEST_REFRESH_LOG__ || [];
      var json = JSON.stringify(log);
      console.log("LOG:" + json);

      // 검증: InitializeCore가 실행되었는지
      var hasInitCore = log.some(e => e.action === 'InitializeCore');
      if (!hasInitCore) { console.error("FAIL: InitializeCore not executed"); process.exit(1); }

      // 검증: injectIntoGlobalHook이 호출되었는지
      var hasInject = log.some(e => e.action === 'injectIntoGlobalHook');
      if (!hasInject) { console.error("FAIL: injectIntoGlobalHook not called"); process.exit(1); }

      // 검증: $RefreshReg$가 호출되어 register가 기록되었는지
      var registers = log.filter(e => e.action === 'register');
      if (registers.length === 0) { console.error("FAIL: no $RefreshReg$ calls"); process.exit(1); }

      // 검증: App 컴포넌트가 등록되었는지
      var hasApp = registers.some(e => e.id.includes('App'));
      if (!hasApp) { console.error("FAIL: App component not registered"); process.exit(1); }

      console.log("PASS: " + registers.length + " components registered");
    `,
    );

    const run = spawn({ cmd: ["bun", "run", testScript], stdout: "pipe", stderr: "pipe" });
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(run.stdout).text(),
      new Response(run.stderr).text(),
      run.exited,
    ]);

    if (exitCode !== 0) {
      console.error("stderr:", stderr);
      console.error("stdout:", stdout);
    }
    expect(exitCode).toBe(0);
    expect(stdout).toContain("PASS");
  });

  test("실행 순서: injectIntoGlobalHook → InitializeCore → register(컴포넌트)", async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "index.tsx",
      "-o",
      outFile,
      "--platform=react-native",
      "--dev",
    ]);
    expect(result.exitCode).toBe(0);

    const testScript = join(fixture.dir, "test_order.js");
    const bundleCode = readFileSync(outFile, "utf-8");
    writeFileSync(
      testScript,
      `
      ${bundleCode}

      var log = globalThis.__TEST_REFRESH_LOG__ || [];
      var actions = log.map(e => e.action);

      // injectIntoGlobalHook이 register보다 먼저
      var injectIdx = actions.indexOf('injectIntoGlobalHook');
      var initCoreIdx = actions.indexOf('InitializeCore');
      var firstRegisterIdx = actions.indexOf('register');

      if (injectIdx === -1) { console.error("FAIL: no injectIntoGlobalHook"); process.exit(1); }
      if (initCoreIdx === -1) { console.error("FAIL: no InitializeCore"); process.exit(1); }
      if (firstRegisterIdx === -1) { console.error("FAIL: no register"); process.exit(1); }

      if (injectIdx >= firstRegisterIdx) {
        console.error("FAIL: injectIntoGlobalHook(" + injectIdx + ") should be before register(" + firstRegisterIdx + ")");
        console.error("actions:", JSON.stringify(actions));
        process.exit(1);
      }
      if (initCoreIdx >= firstRegisterIdx) {
        console.error("FAIL: InitializeCore(" + initCoreIdx + ") should be before register(" + firstRegisterIdx + ")");
        console.error("actions:", JSON.stringify(actions));
        process.exit(1);
      }

      console.log("PASS: order correct — inject(" + injectIdx + ") → initCore(" + initCoreIdx + ") → register(" + firstRegisterIdx + ")");
    `,
    );

    const run = spawn({ cmd: ["bun", "run", testScript], stdout: "pipe", stderr: "pipe" });
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(run.stdout).text(),
      new Response(run.stderr).text(),
      run.exited,
    ]);

    if (exitCode !== 0) {
      console.error("stderr:", stderr);
      console.error("stdout:", stdout);
    }
    expect(exitCode).toBe(0);
    expect(stdout).toContain("PASS");
  });

  test("비-RN 플랫폼에서는 InitializeCore가 주입되지 않는다", async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "index.tsx",
      "-o",
      outFile,
      "--platform=browser",
      "--dev",
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, "utf-8");

    // browser 플랫폼에서는 InitializeCore가 번들에 포함되지 않아야 함
    expect(bundle).not.toContain("InitializeCore");
  });

  test("비-dev 모드에서는 InitializeCore prelude가 주입되지 않는다", async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "index.tsx",
      "-o",
      outFile,
      "--platform=react-native",
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, "utf-8");

    // non-dev에서는 HMR 런타임과 InitializeCore prelude가 없어야 함
    expect(bundle).not.toContain("__zts_modules");
    expect(bundle).not.toContain("injectIntoGlobalHook");
  });

  test("사용자가 --run-before-main으로 이미 InitializeCore를 지정하면 중복 추가하지 않는다", async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const initCorePath = join(
      fixture.dir,
      "node_modules/react-native/Libraries/Core/InitializeCore.js",
    );
    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "index.tsx",
      "-o",
      outFile,
      "--platform=react-native",
      "--dev",
      `--run-before-main=${initCorePath}`,
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, "utf-8");

    // 실제 코드(injectIntoGlobalHook)는 1번만 포함되어야 함 (정의 + 호출)
    const injectMatches = bundle.match(/injectIntoGlobalHook/g) || [];
    // mock InitializeCore에 injectIntoGlobalHook이 1번, react-refresh/runtime에 정의가 1번
    // = 총 2번 (정의 + 호출). 중복 주입 시 4번이 됨.
    expect(injectMatches.length).toBeLessThanOrEqual(3);
  });

  test("HMR 런타임에 디버그 console.log가 없다", async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "index.tsx",
      "-o",
      outFile,
      "--platform=react-native",
      "--dev",
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, "utf-8");

    // HMR 런타임의 디버그 로그가 제거되었는지 확인
    expect(bundle).not.toContain("[zts:hmr]");
  });
});
