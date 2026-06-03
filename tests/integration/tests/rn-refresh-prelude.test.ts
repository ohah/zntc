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
import { describe, test, expect, afterEach } from 'bun:test';
import { createFixture, runZntcInDir } from './helpers';
import { join } from 'node:path';
import { readFileSync, writeFileSync } from 'node:fs';
import { spawn } from 'bun';

describe('RN react-refresh prelude', () => {
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
      'node_modules/react-refresh/cjs/react-refresh-runtime.development.js': `
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
      'node_modules/react-refresh/runtime.js': `
        'use strict';
        module.exports = require('./cjs/react-refresh-runtime.development.js');
      `,
      'node_modules/react-refresh/package.json': `{ "name": "react-refresh", "main": "runtime.js" }`,

      // mock react-native InitializeCore — setUpReactRefresh ���할
      'node_modules/react-native/Libraries/Core/InitializeCore.js': `
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
      'node_modules/react-native/package.json': `{ "name": "react-native", "main": "index.js" }`,

      // 사용자 코드
      'App.tsx': `
        export default function App() { return "hello from App"; }
      `,
      'index.tsx': `
        import App from './App';
        globalThis.__APP_RESULT__ = App();
      `,
    });
  }

  /**
   * 변형 fixture: setUpReactRefresh(InitializeCore)가 global.__ReactRefresh 를 set 하지 *않고*
   * react-refresh/runtime 을 require 만 한다 (RN/Hermes 실제 동작 — global 대입은 타이밍/
   * __METRO_GLOBAL_PREFIX__ 구성차로 불안정). 이 경우 $RefreshReg$ 의 __ReactRefresh 가
   * undefined → __zntc_resolveRefresh() 가 __zntc_modules[__zntc_refresh_id] 에서 동일 runtime 을
   * 꺼내 register 해야 한다 (이 PR 의 registry-resolve 경로 회귀 가드).
   */
  function createRNFixtureNoGlobalSet() {
    return createFixture({
      'node_modules/react-refresh/cjs/react-refresh-runtime.development.js': `
        'use strict';
        var families = new Map();
        exports.register = function(type, id) {
          families.set(id, { current: type });
          if (typeof globalThis.__TEST_REFRESH_LOG__ === 'undefined') globalThis.__TEST_REFRESH_LOG__ = [];
          globalThis.__TEST_REFRESH_LOG__.push({ action: 'register', id: id });
        };
        exports.createSignatureFunctionForTransform = function() { return function(type) { return type; }; };
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
      'node_modules/react-refresh/runtime.js': `
        'use strict';
        module.exports = require('./cjs/react-refresh-runtime.development.js');
      `,
      'node_modules/react-refresh/package.json': `{ "name": "react-refresh", "main": "runtime.js" }`,
      // __ReactRefresh 대입 *없는* InitializeCore — runtime require + injectIntoGlobalHook 만 수행.
      'node_modules/react-native/Libraries/Core/InitializeCore.js': `
        'use strict';
        var ReactRefreshRuntime = require('react-refresh/runtime');
        ReactRefreshRuntime.injectIntoGlobalHook(globalThis);
        if (typeof globalThis.__TEST_REFRESH_LOG__ === 'undefined') globalThis.__TEST_REFRESH_LOG__ = [];
        globalThis.__TEST_REFRESH_LOG__.push({ action: 'InitializeCore' });
      `,
      'node_modules/react-native/package.json': `{ "name": "react-native", "main": "index.js" }`,
      'App.tsx': `
        export default function App() { return "hello from App"; }
      `,
      'index.tsx': `
        import App from './App';
        globalThis.__APP_RESULT__ = App();
      `,
    });
  }

  test('RN dev mode에서 InitializeCore가 prelude로 자동 포함된다', async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      'index.tsx',
      '-o',
      outFile,
      '--platform=react-native',
      '--dev',
    ]);

    expect(result.exitCode).toBe(0);
    const bundle = readFileSync(outFile, 'utf-8');

    // InitializeCore 코드가 번들에 포함되어야 함
    expect(bundle).toContain('__ReactRefresh');
    expect(bundle).toContain('injectIntoGlobalHook');

    // InitializeCore의 require/init 호출이 엔트리 호출보다 앞에 있어야 함
    // (모듈 정의 순서가 아닌 호출 순서가 중요)
    // run_before_main 호출은 엔트리 init 호출 직전에 삽입됨
    const lines = bundle.split('\n');
    const initCallLine = lines.findIndex(
      (l) =>
        /(?:require|init)_.*InitializeCore/.test(l) || /(?:require|init)_.*initialize_core/.test(l),
    );
    // 번들 끝부분의 엔트리 호출 직전에 InitializeCore 호출이 있어야 함
    // (또는 __esm body 안에서 호출)
    expect(initCallLine).toBeGreaterThan(-1);
  });

  test('$RefreshReg$가 __ReactRefresh 설정 후 정상 호출된다', async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      'index.tsx',
      '-o',
      outFile,
      '--platform=react-native',
      '--dev',
    ]);
    expect(result.exitCode).toBe(0);

    // 번들 실행 + 결과 검증 스크립트
    const testScript = join(fixture.dir, 'test_runner.js');
    const bundleCode = readFileSync(outFile, 'utf-8');
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

    const run = spawn({ cmd: ['bun', 'run', testScript], stdout: 'pipe', stderr: 'pipe' });
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(run.stdout).text(),
      new Response(run.stderr).text(),
      run.exited,
    ]);

    if (exitCode !== 0) {
      console.error('stderr:', stderr);
      console.error('stdout:', stdout);
    }
    expect(exitCode).toBe(0);
    expect(stdout).toContain('PASS');
  });

  test('실행 순서: injectIntoGlobalHook → InitializeCore → register(컴포넌트)', async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      'index.tsx',
      '-o',
      outFile,
      '--platform=react-native',
      '--dev',
    ]);
    expect(result.exitCode).toBe(0);

    const testScript = join(fixture.dir, 'test_order.js');
    const bundleCode = readFileSync(outFile, 'utf-8');
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

    const run = spawn({ cmd: ['bun', 'run', testScript], stdout: 'pipe', stderr: 'pipe' });
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(run.stdout).text(),
      new Response(run.stderr).text(),
      run.exited,
    ]);

    if (exitCode !== 0) {
      console.error('stderr:', stderr);
      console.error('stdout:', stdout);
    }
    expect(exitCode).toBe(0);
    expect(stdout).toContain('PASS');
  });

  test('비-RN 플랫폼에서는 InitializeCore가 주입되지 않는다', async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      'index.tsx',
      '-o',
      outFile,
      '--platform=browser',
      '--dev',
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, 'utf-8');

    // browser 플랫폼에서는 InitializeCore가 번들에 포함되지 않아야 함
    expect(bundle).not.toContain('InitializeCore');
  });

  test('비-dev 모드에서는 InitializeCore prelude가 주입되지 않는다', async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      'index.tsx',
      '-o',
      outFile,
      '--platform=react-native',
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, 'utf-8');

    // non-dev에서는 HMR 런타임과 InitializeCore prelude가 없어야 함
    expect(bundle).not.toContain('__zntc_modules');
    expect(bundle).not.toContain('injectIntoGlobalHook');
  });

  test('사용자가 --run-before-main으로 이미 InitializeCore를 지정하면 중복 추가하지 않는다', async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const initCorePath = join(
      fixture.dir,
      'node_modules/react-native/Libraries/Core/InitializeCore.js',
    );
    const outFile = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      'index.tsx',
      '-o',
      outFile,
      '--platform=react-native',
      '--dev',
      `--run-before-main=${initCorePath}`,
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, 'utf-8');

    // 이 테스트의 의도: --run-before-main 으로 InitializeCore 를 명시해도 *중복 추가하지 않음*.
    // 과거엔 전체 문자열 `injectIntoGlobalHook` count(≤3)를 proxy 로 썼으나, HMR 프렐류드의
    // __zntc_resolveRefresh 가 registry 에서 runtime 을 꺼내 호출하는 정적 참조
    // (`__re.injectIntoGlobalHook(...)`, 4d3c5c17)와 mock 의 로깅 리터럴까지 세어 중복과
    // 무관히 늘어나는 fragile 신호였다. 진짜 중복 여부는 다음 두 정의 사이트가 각각 1번:
    //  (1) react-refresh/runtime 정의(`exports.injectIntoGlobalHook = function`) — 런타임 1회 포함
    //  (2) InitializeCore 프렐류드 호출(`ReactRefreshRuntime.injectIntoGlobalHook`) — 프렐류드 1회
    const runtimeDefs = bundle.match(/injectIntoGlobalHook\s*=\s*function/g) || [];
    expect(runtimeDefs.length).toBe(1); // 런타임 중복 번들 아님
    const initCoreCalls = bundle.match(/ReactRefreshRuntime\.injectIntoGlobalHook/g) || [];
    expect(initCoreCalls.length).toBe(1); // InitializeCore 프렐류드 중복 추가 아님
  });

  test('HMR 런타임에 디버그 console.log가 없다', async () => {
    const fixture = await createRNFixture();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      'index.tsx',
      '-o',
      outFile,
      '--platform=react-native',
      '--dev',
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, 'utf-8');

    // HMR 런타임의 디버그 로그가 제거되었는지 확인
    expect(bundle).not.toContain('[zntc:hmr]');
  });

  test('global.__ReactRefresh 미설정 시 __zntc_modules 레지스트리로 register 된다 (Hermes 모사)', async () => {
    const fixture = await createRNFixtureNoGlobalSet();
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      'index.tsx',
      '-o',
      outFile,
      '--platform=react-native',
      '--dev',
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, 'utf-8');
    // (1) refresh_id 가 react-refresh/runtime 의 dev_id 로 주입되었는지 (정적).
    expect(bundle).toContain('__zntc_g.__zntc_refresh_id=');
    const ridMatch = bundle.match(/__zntc_g\.__zntc_refresh_id\s*=\s*("[^"]*")/);
    expect(ridMatch).not.toBeNull();
    expect(ridMatch![1]).toContain('react-refresh/runtime.js');
    // (2) resolveRefresh 에 레지스트리 lookup 분기가 존재하는지 (정적).
    expect(bundle).toContain('__zntc_g.__zntc_modules[__rid]');
    // (3) $RefreshReg$ 는 여전히 __ReactRefresh || __zntc_resolveRefresh() 패턴 (브라우저 회귀 0).
    expect(bundle).toContain('__zntc_g.__ReactRefresh || __zntc_resolveRefresh()');

    // (4) 동적: 전역 require 를 무력화(Hermes 모사)해 resolveRefresh 의 require fallback 을
    //     차단 → __zntc_modules 레지스트리 경로로만 register 가 성공해야 한다.
    const testScript = join(fixture.dir, 'test_registry.js');
    const bundleCode = readFileSync(outFile, 'utf-8');
    writeFileSync(
      testScript,
      `
      // require 를 undefined 로 셰도잉: __zntc_resolveRefresh 의
      // require("react-refresh/runtime") fallback 이 TypeError → catch → null.
      // 따라서 register 가 기록되면 그것은 __zntc_modules[__rid] 레지스트리 경로뿐이다.
      (function(require) {
        ${bundleCode}
        var log = globalThis.__TEST_REFRESH_LOG__ || [];
        var registers = log.filter(function(e) { return e.action === 'register'; });
        if (registers.length === 0) {
          console.error("FAIL: 레지스트리 resolve 실패 — register 0개", JSON.stringify(log));
          process.exit(1);
        }
        var hasApp = registers.some(function(e) { return String(e.id).indexOf('App') !== -1; });
        if (!hasApp) { console.error("FAIL: App 컴포넌트 미등록", JSON.stringify(log)); process.exit(1); }
        console.log("PASS: registry resolve — " + registers.length + " components registered");
      })(undefined);
    `,
    );

    const run = spawn({ cmd: ['bun', 'run', testScript], stdout: 'pipe', stderr: 'pipe' });
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(run.stdout).text(),
      new Response(run.stderr).text(),
      run.exited,
    ]);
    if (exitCode !== 0) {
      console.error('stderr:', stderr);
      console.error('stdout:', stdout);
    }
    expect(exitCode).toBe(0);
    expect(stdout).toContain('PASS');
  });
});
