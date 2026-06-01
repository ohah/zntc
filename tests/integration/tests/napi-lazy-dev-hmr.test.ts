import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join, basename } from 'node:path';
import { writeFileSync, realpathSync } from 'node:fs';
import vm from 'node:vm';
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

  // RFC_LAZY_DEV_MODULE_HMR PR-5: dev_split 에 react_refresh 전파 → split 청크의 React
  // 컴포넌트가 Fast Refresh 와이어링(실제 $RefreshReg$ 바인딩 + `__zntc_make_hot(id).accept()`)
  // 을 받는다. 이게 "리로드 없이 state 보존"의 emit-side 조각. 컴포넌트를 *별도 청크*
  // (2 entry 가 정적 공유)에 두어 cross-chunk(비-entry 청크) Fast Refresh 를 가드한다.
  // (브라우저에서의 실제 state 보존 e2e = 에픽 capstone, 별도.)
  test('split 청크 React 컴포넌트가 Fast Refresh accept + 실제 $RefreshReg$ 바인딩을 받는다', async () => {
    const fixture = await createFixture({
      // classic JSX → React.createElement (jsx-runtime 불요, react stub 의 createElement 사용).
      'node_modules/react/package.json': '{"name":"react","main":"index.js"}',
      'node_modules/react/index.js':
        'exports.useState=function(i){return [i,function(){}]};exports.createElement=function(){return {}};module.exports.default=exports;',
      'Counter.tsx':
        "import * as React from 'react';\n" +
        'export function Counter(){ const [n]=React.useState(0); return React.createElement("div",null,String(n)); }',
      'a.tsx': "import { Counter } from './Counter';\nglobalThis.__A = typeof Counter;",
      'b.tsx': "import { Counter } from './Counter';\nglobalThis.__B = typeof Counter;",
    });
    cleanup = fixture.cleanup;
    const dir = realpathSync(fixture.dir);

    const r = await build({
      entryPoints: [join(dir, 'a.tsx'), join(dir, 'b.tsx')],
      platform: 'browser',
      devMode: true,
      splitting: true,
      format: 'iife',
      lazyCompilation: true,
      rootDir: dir,
      reactRefresh: true,
      jsx: 'classic',
    });
    expect(r.errors ?? []).toHaveLength(0);
    const outs = (r.outputFiles ?? []).map((o) => ({ path: basename(o.path), text: o.text }));

    // Counter 는 2 entry 가 정적 공유 → 별도 chunk-*.js (비-entry).
    const shared = outs.find(
      (o) => o.path.startsWith('chunk-') && o.text.includes('function Counter'),
    );
    expect(shared).toBeDefined();
    const entries = outs.filter((o) => o.path === 'a.js' || o.path === 'b.js');
    expect(entries.length).toBe(2);

    const t = shared!.text;
    // 컴포넌트 등록 (transform-level — react_refresh 없이도 나오나 함께 가드).
    expect(t.includes('$RefreshReg$(')).toBe(true);
    // PR-5 핵심 1 — Fast Refresh accept 주입 (이게 있어야 apply_update 가 리로드 대신 hot-replace).
    expect(/__zntc_make_hot\([^)]*\)\.accept\(/.test(t)).toBe(true);
    // PR-5 핵심 2 — 실제 $RefreshReg$ 바인딩 save/restore (no-op 글로벌이 아닌 react-refresh register).
    expect(t.includes('__prevRefreshReg')).toBe(true);
    // cross-chunk: 비-entry 청크라 $RefreshReg$/resolveRefresh 를 글로벌(__zntc_g/entry 노출)로 해석.
    expect(t.includes('__zntc_g.$RefreshReg$')).toBe(true);
    expect(t.includes('__zntc_resolveRefresh()')).toBe(true);

    // entry 청크엔 컴포넌트가 없으므로 그 reg/accept 가 새지 않는다.
    for (const e of entries) {
      expect(e.text.includes('function Counter')).toBe(false);
      expect(/__zntc_make_hot\(["'][^"']*Counter[^"']*["']\)\.accept\(/.test(e.text)).toBe(false);
    }
  });

  // #4079 회귀: dev_split wrap-all 이후 동적 청크의 entry 모듈이 __esm 래핑되어
  // emitCjsEntryExports 경로를 안 타 → `__zntc_require("<chunk>")`(= `import('./route')`
  // 결과)에 entry export(render)가 없어 `m.render is not a function` → lazy 라우트가 렌더 안 됨.
  // 동적 청크가 entry 모듈 export 를 exported_name 키로 노출하는지 가드.
  test('dev_split 동적 청크가 entry 모듈 export 를 노출 (import() 가 render 받음, #4079 회귀)', async () => {
    const fixture = await createFixture({
      'util.ts': "export function fmt(s: string){ return 'UTIL[' + s + ']'; }",
      'Chart.ts': "import { fmt } from './util';\nexport function chart(){ return fmt('chart'); }",
      'route.ts': "import { chart } from './Chart';\nexport function render(){ return chart(); }",
      'entry.ts':
        "async function go(){ const m = await import('./route'); globalThis.__OUT = m.render(); }\ngo();",
    });
    cleanup = fixture.cleanup;
    const dir = realpathSync(fixture.dir);
    const opts = {
      entryPoints: [join(dir, 'entry.ts')],
      platform: 'browser' as const,
      devMode: true,
      splitting: true,
      format: 'iife' as const,
      lazyCompilation: true,
      rootDir: dir,
    };
    // 1) base 빌드 → route 가 동적 import 타겟이라 lazy seed.
    const base = await build(opts);
    expect(base.errors ?? []).toHaveLength(0);
    const seed = (base.lazySeeds ?? []).find((s) => s.path.endsWith('route.ts'));
    expect(seed).toBeDefined();
    // 2) force-parse(= dev 서버 materialize 동치) → route 가 정식 청크로 emit.
    const r = await build({ ...opts, lazyForceParse: [seed!.path] });
    expect(r.errors ?? []).toHaveLength(0);
    const routeChunk = (r.outputFiles ?? []).find(
      (o) => o.path.includes('route-') && o.text.includes('function render'),
    );
    expect(routeChunk).toBeDefined();
    // 핵심 가드: 동적 청크가 entry 모듈 export 를 exported_name 키로 노출 → import().render 동작.
    expect(routeChunk!.text.includes('exports.render')).toBe(true);
  });

  // entry 모듈이 `export * as ns`(re_export_namespace)를 섞으면, 청크에 없는 바인딩으로
  // `exports.ns = ns`(ReferenceError crash) 를 emit 하면 안 되고, entry 네임스페이스 getter 로
  // `exports.ns = exports_route.ns`(유효·정확) 를 emit 해야 한다. .local(render) + ns 둘 다 노출.
  test('동적 청크 entry 의 re_export_namespace 는 네임스페이스 getter 로 노출 (crash 패턴 없음)', async () => {
    const fixture = await createFixture({
      'dep.ts': 'export const a = 1;\nexport const b = 2;',
      'route.ts': "export * as ns from './dep';\nexport function render(){ return 'R'; }",
      'entry.ts':
        "async function go(){ const m = await import('./route'); globalThis.__OUT = m.render(); }\ngo();",
    });
    cleanup = fixture.cleanup;
    const dir = realpathSync(fixture.dir);
    const opts = {
      entryPoints: [join(dir, 'entry.ts')],
      platform: 'browser' as const,
      devMode: true,
      splitting: true,
      format: 'iife' as const,
      lazyCompilation: true,
      rootDir: dir,
    };
    const base = await build(opts);
    const seed = (base.lazySeeds ?? []).find((s) => s.path.endsWith('route.ts'));
    expect(seed).toBeDefined();
    const r = await build({ ...opts, lazyForceParse: [seed!.path] });
    expect(r.errors ?? []).toHaveLength(0);
    const routeChunk = (r.outputFiles ?? []).find((o) => o.path.includes('route-'));
    expect(routeChunk).toBeDefined();
    expect(routeChunk!.text.includes('exports.render')).toBe(true); // .local 노출
    // re_export_namespace 도 네임스페이스 getter 로 노출(`exports.ns = exports_route.ns`).
    expect(/exports\.ns\s*=\s*exports_\w+\.ns;/.test(routeChunk!.text)).toBe(true);
    // crash 패턴(`exports.ns = ns;` — 청크에 ns 바인딩 없음) 부재.
    expect(/exports\.ns\s*=\s*ns;/.test(routeChunk!.text)).toBe(false);
  });

  // #4079 후속: `export { default, meta } from './Page'`(re-export forwarding) 동적 route.
  // 예전 `.local` 만 노출하던 코드는 re-export 를 스킵해 `import('./route').default` 가 undefined →
  // 라우트 렌더 실패. 이제 entry 네임스페이스 getter(`exports.default = exports_route.default`)로
  // re-export 체인을 정확히 해석하는지 **런타임**으로 가드(emit 문자열이 아니라 실제 값 검증).
  test('동적 청크가 re-export forwarding(export {default,meta} from) 을 런타임에 정확히 노출', async () => {
    const fixture = await createFixture({
      'Page.ts': "export default function Page(){ return 'PAGE'; }\nexport const meta = 'M';",
      'route.ts': "export { default, meta } from './Page';",
      // import() 를 *정의만* 하고 top-level 에서 실행하지 않는다 — route 는 그래도 동적 import
      // 타겟(seed)이지만, vm 안에서 native import() 폴백으로 비동기 reject 하는 일은 없다.
      'entry.ts': "globalThis.loadRoute = () => import('./route');",
    });
    cleanup = fixture.cleanup;
    const dir = realpathSync(fixture.dir);
    const opts = {
      entryPoints: [join(dir, 'entry.ts')],
      platform: 'browser' as const,
      devMode: true,
      splitting: true,
      format: 'iife' as const,
      lazyCompilation: true,
      rootDir: dir,
    };
    const base = await build(opts);
    const seed = (base.lazySeeds ?? []).find((s) => s.path.endsWith('route.ts'));
    expect(seed).toBeDefined();
    const r = await build({ ...opts, lazyForceParse: [seed!.path] });
    expect(r.errors ?? []).toHaveLength(0);
    const entryChunk = (r.outputFiles ?? []).find((o) => o.path.endsWith('entry.js'));
    const routeChunk = (r.outputFiles ?? []).find((o) => o.path.includes('route-'));
    expect(entryChunk && routeChunk).toBeTruthy();
    // emit 가드: default·meta 가 entry 네임스페이스 getter 로 노출(re-export 해석).
    expect(/exports\.default\s*=\s*exports_\w+\.default;/.test(routeChunk!.text)).toBe(true);
    expect(/exports\.meta\s*=\s*exports_\w+\.meta;/.test(routeChunk!.text)).toBe(true);

    // 런타임 가드: entry 청크(=__zntc_require 코어) + route 청크 로드 후 require → 실제 값.
    // entry 의 go() 가 vm 안에서 import('./route') 를 시도하면 비동기 reject(무시) 하므로 sync
    // 검사(require)는 그 전에 완료된다.
    const g: Record<string, unknown> = { console };
    g.globalThis = g;
    const ctx = vm.createContext(g);
    vm.runInContext(entryChunk!.text, ctx); // __zntc_require 코어 + entry register
    vm.runInContext(routeChunk!.text, ctx); // route.js register
    const mods = g.__zntc_mods as Record<string, unknown>;
    const id = Object.keys(mods).find((k) => /route/.test(k))!;
    const required = (g.__zntc_require as (k: string) => Record<string, unknown>)(id);
    expect(typeof required.default).toBe('function');
    expect((required.default as () => string)()).toBe('PAGE');
    expect(required.meta).toBe('M');
  });
});
