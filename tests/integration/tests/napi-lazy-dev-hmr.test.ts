import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join, basename } from 'node:path';
import { writeFileSync, realpathSync } from 'node:fs';
import { createFixture, writeOutputs, runNode } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// RFC_LAZY_DEV_MODULE_HMR PR-2 (코어): dev+code_splitting+lazy 빌드가 모듈을 개별
// __esm/__commonJS factory 로 wrap 하고, *글로벌(globalThis-backed)* `__zntc_modules`
// 레지스트리에 per-module 등록한다 → 청크 경계를 넘는 hot-replace 가능(#4038 재해결).
// cross-chunk *정적* 해석은 production `__zntc_require` 가 그대로 담당(하이브리드).
//
// 이 테스트는 그 런타임 substrate 를 실제 Node 실행으로 가드한다:
//   (1) cross-chunk side-effect init(`__zntc_modules["shared.ts"].fn()`)이 등록된
//       핸들을 찾아 `undefined.fn()`(#4038 BUG1) 없이 동작.
//   (2) 모든 청크의 모듈이 *하나의* globalThis-backed `__zntc_modules` 에 등록.
//   (3) `__zntc_apply_update`/`__zntc_make_hot` 머신러리가 실제로 모듈을 hot-replace
//       하고 앱 state 를 보존(리로드 없음).
// (full dev-server transport + 브라우저 state 보존 e2e 는 후속 PR — test.fixme 유지.)

describe('NAPI lazy dev split HMR runtime (RFC_LAZY_DEV_MODULE_HMR PR-2)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('cross-chunk init 이 글로벌 per-module 레지스트리로 동작 + apply_update hot-replace+state 보존', async () => {
    // 2개 entry(a,b)가 같은 shared 를 import → shared 는 *별도* 청크로 분리되어
    // cross-chunk static dep 가 된다 (#4038 의 정확한 형상).
    const fixture = await createFixture({
      'shared.ts': "export const s = 'SHARED_V1';\nexport function helper(){ return s + '!'; }",
      'a.ts':
        "import { s, helper } from './shared';\nglobalThis.__A_RESULT = 'A ' + s + ' ' + helper();",
      'b.ts': "import { helper } from './shared';\nglobalThis.__B_RESULT = 'B ' + helper();",
    });
    cleanup = fixture.cleanup;
    // macOS 의 /tmp → /private/tmp 심볼릭 링크 때문에 번들러가 해석한 모듈 경로와
    // rootDir 의 prefix 가 어긋나면 dev_id 가 절대경로로 남는다. realpath 로 정규화해
    // dev_id 를 안정 상대경로(shared.ts 등)로 만든다(실제 dev 서버와 동일 형상).
    const dir = realpathSync(fixture.dir);

    const r = await build({
      entryPoints: [join(dir, 'a.ts'), join(dir, 'b.ts')],
      platform: 'browser',
      devMode: true,
      splitting: true,
      format: 'iife',
      lazyCompilation: true,
      rootDir: dir, // dev_id 를 상대 경로(shared.ts 등)로 — 실제 dev 서버와 동일
    });
    expect(r.errors ?? []).toHaveLength(0); // 무음 에러 false-pass 방지
    const outs = (r.outputFiles ?? []).map((o) => ({ path: basename(o.path), text: o.text }));
    expect(outs.length).toBeGreaterThanOrEqual(3); // a.js, b.js, chunk-<shared>.js

    // 청크 종류 분리: entry(a.js/b.js) vs shared(chunk-*.js).
    const entries = outs.filter((o) => o.path === 'a.js' || o.path === 'b.js');
    const shared = outs.filter((o) => o.path.startsWith('chunk-'));
    expect(entries.length).toBe(2);
    expect(shared.length).toBeGreaterThanOrEqual(1);

    // 출력 청크를 dist 에 쓰고, 로드 순서(shared 먼저 등록 → entry 가 __zntc_require)
    // 를 보장하는 드라이버로 실제 Node 실행한다. entry 청크는 끝에 자체
    // `globalThis.__zntc_require("a.js")` bootstrap 이 있어 require 만 하면 실행된다.
    const dist = join(dir, 'dist');
    writeOutputs(dist, outs);
    const loadOrder = [...shared, ...entries]
      .map((o) => `require(${JSON.stringify('./' + o.path)});`)
      .join('\n');

    const driver = `
const g = globalThis;
g.__zntc_public_path = '';
${loadOrder}

// (3) apply_update hot-replace + state 보존: 빌드가 깐 *실제* 런타임 머신러리
// (__zntc_apply_update/__zntc_make_hot/글로벌 등록 __esm)만 사용. ⚠️ 여기서 virt.ts 와
// code payload 는 빌드 산출이 아닌 *합성* 이다 — PR-2 가 깐 substrate 가 hot-replace+
// state 보존을 실제로 수행하는지만 가드(빌드의 per-module HMR codegen 검증 = 후속 PR
// dev 서버 transport 의 e2e). (1)/(2) 만 빌드 codegen 에 묶여 있다.
// 앱 state sentinel — 리로드(fallback)되면 사라진다.
g.__APP_STATE = 'PRESERVED';
// 모듈에 accept 콜백 등록(import.meta.hot.accept 동치).
g.__zntc_make_hot('virt.ts').accept(function (exp) { g.__HOT_NEW = exp && exp.v; });
// dev 서버가 보낼 per-module 업데이트와 동일한 형상(eval payload). 글로벌 등록
// __esm 으로 virt.ts 를 새로 등록 → apply_update 가 fn() 실행 + accept(exports).
g.__zntc_apply_update([{
  id: 'virt.ts',
  code: 'globalThis.__esm({"virt.ts": function(){ globalThis.__virt_exports.v = "HOT_OK"; }}, void 0, (globalThis.__virt_exports = {}))'
}]);

const m = g.__zntc_modules || {};
process.stdout.write(JSON.stringify({
  a: g.__A_RESULT,
  b: g.__B_RESULT,
  hasApply: typeof g.__zntc_apply_update === 'function',
  hasMakeHot: typeof g.__zntc_make_hot === 'function',
  sharedRegistered: !!(m['shared.ts'] && typeof m['shared.ts'].fn === 'function'),
  aRegistered: !!m['a.ts'],
  bRegistered: !!m['b.ts'],
  globalBacked: g.__zntc_modules === (typeof global !== 'undefined' ? global.__zntc_modules : undefined),
  hotNew: g.__HOT_NEW,
  statePreserved: g.__APP_STATE === 'PRESERVED',
}));
`;
    const driverPath = join(dist, 'run.cjs');
    writeFileSync(driverPath, driver);

    const { stdout } = await runNode(driverPath);
    const res = JSON.parse(stdout);

    // (1) #4038 런타임 fix: cross-chunk side-effect init 이 등록 핸들을 찾는다.
    expect(res.a).toBe('A SHARED_V1 SHARED_V1!');
    expect(res.b).toBe('B SHARED_V1!');
    // (2) 글로벌 per-module 레지스트리 — 모든 청크 모듈이 *하나의* globalThis 에 등록.
    expect(res.sharedRegistered).toBe(true);
    expect(res.aRegistered).toBe(true);
    expect(res.bRegistered).toBe(true);
    expect(res.globalBacked).toBe(true);
    // (3) hot-replace 머신러리 동작 + state 보존.
    expect(res.hasApply).toBe(true);
    expect(res.hasMakeHot).toBe(true);
    expect(res.hotNew).toBe('HOT_OK');
    expect(res.statePreserved).toBe(true);
  });
});
