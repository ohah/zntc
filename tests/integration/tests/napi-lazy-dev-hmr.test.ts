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

  // dev_split lazy 빌드 → entry+lazy 청크를 vm 으로 로드 → 지정 lazy 모듈 require.
  // #4096 의 cross-chunk 예약어 default 바인딩 해석을 다양한 형태로 잠그는 lock 테스트 공용.
  async function loadDevSplitLazy(
    files: Record<string, string>,
    lazyFile: string,
  ): Promise<{ lazyText: string; exports: Record<string, unknown> }> {
    const fixture = await createFixture(files);
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
    const seed = (base.lazySeeds ?? []).find((s) => s.path.endsWith(lazyFile));
    expect(seed).toBeDefined();
    const r = await build({ ...opts, lazyForceParse: [seed!.path] });
    expect(r.errors ?? []).toHaveLength(0);
    const entryChunk = (r.outputFiles ?? []).find((o) => o.path.endsWith('entry.js'));
    const lazyPrefix = lazyFile.replace(/\.tsx?$/, '') + '-';
    const lazyChunk = (r.outputFiles ?? []).find((o) => o.path.includes(lazyPrefix));
    expect(entryChunk && lazyChunk).toBeTruthy();
    // 예약어 축약 destructuring(`const { default }`) 이 없어야 한다(SyntaxError 원인).
    expect(/const\s*\{[^}]*\bdefault\b(?!\$)[^}:]*\}\s*=/.test(lazyChunk!.text)).toBe(false);
    const g: Record<string, unknown> = { console };
    g.globalThis = g;
    const ctx = vm.createContext(g);
    vm.runInContext(entryChunk!.text, ctx); // 예약어 SyntaxError 면 throw
    vm.runInContext(lazyChunk!.text, ctx);
    const mods = g.__zntc_mods as Record<string, unknown>;
    const re = new RegExp(lazyFile.replace(/\.tsx?$/, ''));
    const id = Object.keys(mods).find((k) => re.test(k))!;
    return {
      lazyText: lazyChunk!.text,
      exports: (g.__zntc_require as (k: string) => Record<string, unknown>)(id),
    };
  }

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

  // dev_split 크로스청크 공유 의존 해석: lazy 청크가 다른 청크의 **공유 CJS(`require()`)** 와
  // **ESM(`import`)** 의존을 참조할 때, 예전엔 lexical `require_X`/`init_X`(정의자 청크 팩토리
  // 스코프에 갇힘)로 emit 돼 `ReferenceError`(react/jsx-runtime 등 → lazy React 렌더 실패)였다.
  // 이제 글로벌 `__zntc_modules` 레지스트리로 해석(ESM 과 동일, useDevModuleRegistry). 런타임으로
  // CJS+ESM 둘 다 크로스청크 해석되는지 가드.
  test('dev_split lazy 청크가 크로스청크 공유 CJS(require) + ESM(import) 을 레지스트리로 해석', async () => {
    const fixture = await createFixture({
      'lib.js': "module.exports = { greet: function(){ return 'HELLO'; }, n: 42 };",
      'esmdep.ts': "export const tag = 'ESM';\nexport function mk(){ return tag; }",
      'Card.ts':
        "const lib = require('./lib.js');\nimport { mk } from './esmdep';\nexport function card(){ return lib.greet() + lib.n + mk(); }",
      // entry 가 lib·esmdep 를 정적으로 써서 그 청크(entry)에 두고, Card 는 동적 import(lazy 청크).
      'entry.ts':
        "const lib = require('./lib.js');\nimport { mk } from './esmdep';\nglobalThis.E = lib.n + mk();\nglobalThis.loadCard = () => import('./Card');",
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
    const seed = (base.lazySeeds ?? []).find((s) => s.path.endsWith('Card.ts'));
    expect(seed).toBeDefined();
    const r = await build({ ...opts, lazyForceParse: [seed!.path] });
    expect(r.errors ?? []).toHaveLength(0);
    const entryChunk = (r.outputFiles ?? []).find((o) => o.path.endsWith('entry.js'));
    const cardChunk = (r.outputFiles ?? []).find((o) => o.path.includes('Card-'));
    expect(entryChunk && cardChunk).toBeTruthy();
    // emit 가드: Card 청크가 lexical `require_lib`(정의자 청크 갇힘) 대신 레지스트리를 쓴다.
    expect(/\brequire_lib\w*\b/.test(cardChunk!.text)).toBe(false);
    expect(/__zntc_modules\[/.test(cardChunk!.text)).toBe(true);

    // 런타임 가드: entry 청크(lib·esmdep 등록) + Card 청크 로드 후 require → 크로스청크 실값.
    const g: Record<string, unknown> = { console };
    g.globalThis = g;
    const ctx = vm.createContext(g);
    vm.runInContext(entryChunk!.text, ctx); // 공유 lib/esmdep 를 __zntc_modules 에 등록
    vm.runInContext(cardChunk!.text, ctx);
    const mods = g.__zntc_mods as Record<string, unknown>;
    const id = Object.keys(mods).find((k) => /Card/.test(k))!;
    const required = (g.__zntc_require as (k: string) => Record<string, unknown>)(id);
    expect((required.card as () => string)()).toBe('HELLO42ESM');
  });

  // dev_split lazy 청크의 **re-export-from-CJS / side-effect** 크로스청크 해석. 예전엔 esm_wrap 의
  // re-export/init lowering 이 `dev_mode and !code_splitting` 게이트(#4038 잔재)라 splitting 시
  // lexical `require_X`/`init_X` 로 빠져 정의자 청크 스코프에 갇힘 → 크로스청크 ReferenceError.
  // 이제 useDevModuleRegistry/isDevSplit 로 글로벌 레지스트리 해석 → `export { x } from './cjs'` +
  // side-effect `import` 가 lazy 청크에서 동작. 런타임으로 가드.
  test('dev_split lazy 청크가 re-export-from-CJS(export {x} from) + side-effect 를 레지스트리로 해석', async () => {
    const fixture = await createFixture({
      'cjslib.js': "module.exports = { val: 7, greet: function(){ return 'CJS'; } };",
      'side.ts': 'globalThis.__SIDE = (globalThis.__SIDE || 0) + 1;',
      // 라우트가 CJS 에서 named re-export + side-effect import.
      'Route.ts':
        "import './side';\nexport { val, greet } from './cjslib.js';\nexport function r(){ return 'R'; }",
      // entry 가 cjslib·side 를 정적으로 써서 entry 청크에 두고, Route 는 동적 import(lazy 청크).
      'entry.ts':
        "import './side';\nimport { val } from './cjslib.js';\nglobalThis.E = val;\nglobalThis.load = () => import('./Route');",
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
    const seed = (base.lazySeeds ?? []).find((s) => s.path.endsWith('Route.ts'));
    expect(seed).toBeDefined();
    const r = await build({ ...opts, lazyForceParse: [seed!.path] });
    expect(r.errors ?? []).toHaveLength(0);
    const entryChunk = (r.outputFiles ?? []).find((o) => o.path.endsWith('entry.js'));
    const routeChunk = (r.outputFiles ?? []).find((o) => o.path.includes('Route-'));
    expect(entryChunk && routeChunk).toBeTruthy();
    // emit 가드: re-export getter 가 lexical `require_cjslib`(정의자 청크 갇힘) 대신 레지스트리.
    expect(/\brequire_cjslib\w*\b/.test(routeChunk!.text)).toBe(false);

    // 런타임 가드: entry(cjslib·side 등록) + Route 로드 후 require → 크로스청크 실값 + side-effect.
    const g: Record<string, unknown> = { console };
    g.globalThis = g;
    const ctx = vm.createContext(g);
    vm.runInContext(entryChunk!.text, ctx);
    vm.runInContext(routeChunk!.text, ctx);
    const mods = g.__zntc_mods as Record<string, unknown>;
    const id = Object.keys(mods).find((k) => /Route/.test(k))!;
    const required = (g.__zntc_require as (k: string) => Record<string, unknown>)(id);
    expect(required.val).toBe(7); // named re-export from CJS, cross-chunk
    expect((required.greet as () => string)()).toBe('CJS');
    expect((required.r as () => string)()).toBe('R');
    expect(g.__SIDE).toBe(1); // side-effect import 실행(레지스트리 init), 1회
  });

  // dev_split lazy 청크에서 `export { default } from './cjs'`(예약어 export 이름).
  // 예전엔 chunk 수준 cross-chunk import 가 `const { default, named } = __zntc_require(...)`
  // 로 emit 돼 **예약어 축약 destructuring → SyntaxError**(청크 전체 parse 실패)였다.
  // dev_split 은 per-module 레지스트리가 심볼을 참조 지점에서 직접 해석(getter)하므로
  // 이 chunk 수준 destructuring 은 죽은 코드 → side-effect `__zntc_require(...)` 만 남겨
  // SyntaxError 제거. default 값 자체는 `_default = __toESM(__zntc_modules[...].fn()).default`
  // 로 레지스트리에서 채워진다. parse + 실값을 런타임으로 가드.
  test('dev_split lazy 청크가 re-export default(export {default} from CJS) 를 SyntaxError 없이 노출', async () => {
    const fixture = await createFixture({
      'cjslib.js':
        "module.exports = function(){ return 'CJSDEFAULT'; };\nmodule.exports.named = 9;",
      'Route.ts':
        "export { default, named } from './cjslib.js';\nexport function r(){ return 'R'; }",
      'entry.ts':
        "import lib from './cjslib.js';\nglobalThis.E = lib;\nglobalThis.load = () => import('./Route');",
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
    const seed = (base.lazySeeds ?? []).find((s) => s.path.endsWith('Route.ts'));
    expect(seed).toBeDefined();
    const r = await build({ ...opts, lazyForceParse: [seed!.path] });
    expect(r.errors ?? []).toHaveLength(0);
    const entryChunk = (r.outputFiles ?? []).find((o) => o.path.endsWith('entry.js'));
    const routeChunk = (r.outputFiles ?? []).find((o) => o.path.includes('Route-'));
    expect(entryChunk && routeChunk).toBeTruthy();
    // emit 가드: 예약어 축약 destructuring(`const { default ...`) 이 없어야 한다(SyntaxError 원인).
    expect(/const\s*\{[^}]*\bdefault\b(?!\$)[^}:]*\}\s*=/.test(routeChunk!.text)).toBe(false);

    // 런타임 가드: Route 청크가 parse 되고(runInContext 가 안 던짐) default/named 실값이 맞아야 한다.
    const g: Record<string, unknown> = { console };
    g.globalThis = g;
    const ctx = vm.createContext(g);
    vm.runInContext(entryChunk!.text, ctx);
    vm.runInContext(routeChunk!.text, ctx); // 예약어 SyntaxError 면 여기서 throw
    const mods = g.__zntc_mods as Record<string, unknown>;
    const id = Object.keys(mods).find((k) => /Route/.test(k))!;
    const required = (g.__zntc_require as (k: string) => Record<string, unknown>)(id);
    expect((required.default as () => string)()).toBe('CJSDEFAULT'); // 예약어 default re-export, cross-chunk
    expect(required.named).toBe(9);
    expect((required.r as () => string)()).toBe('R');
  });

  // dev_split lazy 청크에서 `import def from './shared'`(예약어 default *import*).
  // dep 청크(emitLazyEntryExportAll)는 hoisted 로컬을 *local 명*(`_default`)으로 노출하므로
  // 소비자는 export 키 `default` 가 아니라 local 키로 destructure 해야 한다(`const { _default }`).
  // 예전엔 `const { default }` 축약 → SyntaxError. 이제 chunk.zig 가 canonical 모듈을 들고
  // emitter 가 resolveToLocalName 으로 `_default` 키를 emit → parse + 실값.
  test('dev_split lazy 청크가 default import(import def from)를 SyntaxError 없이 해석', async () => {
    const fixture = await createFixture({
      // 익명 default 함수(→ 합성 `_default`) 를 lazy 청크가 import 해 호출.
      'esmdep.ts': "export default function(){ return 'DEF'; }",
      'Card.ts': "import def from './esmdep';\nexport function card(){ return def(); }",
      'entry.ts':
        "import def from './esmdep';\nglobalThis.E = def();\nglobalThis.load = () => import('./Card');",
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
    const seed = (base.lazySeeds ?? []).find((s) => s.path.endsWith('Card.ts'));
    expect(seed).toBeDefined();
    const r = await build({ ...opts, lazyForceParse: [seed!.path] });
    expect(r.errors ?? []).toHaveLength(0);
    const entryChunk = (r.outputFiles ?? []).find((o) => o.path.endsWith('entry.js'));
    const cardChunk = (r.outputFiles ?? []).find((o) => o.path.includes('Card-'));
    expect(entryChunk && cardChunk).toBeTruthy();
    // 예약어 축약 destructuring(`const { default ...`) 이 없어야 한다(SyntaxError 원인).
    expect(/const\s*\{[^}]*\bdefault\b(?!\$)[^}:]*\}\s*=/.test(cardChunk!.text)).toBe(false);

    const g: Record<string, unknown> = { console };
    g.globalThis = g;
    const ctx = vm.createContext(g);
    vm.runInContext(entryChunk!.text, ctx);
    vm.runInContext(cardChunk!.text, ctx); // 예약어 SyntaxError 면 throw
    const mods = g.__zntc_mods as Record<string, unknown>;
    const id = Object.keys(mods).find((k) => /Card/.test(k))!;
    const required = (g.__zntc_require as (k: string) => Record<string, unknown>)(id);
    expect((required.card as () => string)()).toBe('DEF'); // cross-chunk default import 실값
  });

  // ── #4096 lock: cross-chunk 예약어 default 바인딩 해석을 다양한 형태로 회귀 가드 ──
  // resolveToLocalName 의 named-default 경로(`export default function foo` → canonical `foo`,
  // `_default` 합성 아님)를 re-export 로 가드.
  test('lock: named default(export default function foo) re-export cross-chunk 해석', async () => {
    const { exports } = await loadDevSplitLazy(
      {
        'dep.ts': "export default function foo(){ return 'NAMEDDEF'; }\nexport const x = 1;",
        'Route.ts': "export { default } from './dep';",
        'entry.ts':
          "import f from './dep';\nglobalThis.E = f();\nglobalThis.r = () => import('./Route');",
      },
      'Route.ts',
    );
    expect((exports.default as () => string)()).toBe('NAMEDDEF');
  });

  // named-default 의 *import*(lexical 바인딩) 경로 — re-export(getter)와 다른 emission.
  test('lock: named default(export default function foo) import cross-chunk 해석', async () => {
    const { exports } = await loadDevSplitLazy(
      {
        'dep.ts': "export default function foo(){ return 'NDI'; }",
        'Route.ts': "import f from './dep';\nexport function r(){ return f(); }",
        'entry.ts':
          "import f from './dep';\nglobalThis.E = f();\nglobalThis.r = () => import('./Route');",
      },
      'Route.ts',
    );
    expect((exports.r as () => string)()).toBe('NDI');
  });

  // `export { local as default }` — local 심볼을 default export 키로 alias. resolveToLocalName
  // 이 default→local 체인을 정확히 따라가야 cross-chunk 값이 맞는다.
  test('lock: export { x as default } aliased default re-export cross-chunk 해석', async () => {
    const { exports } = await loadDevSplitLazy(
      {
        'dep.ts': "const val = 'ALIASED';\nexport { val as default };",
        'Route.ts': "export { default } from './dep';",
        'entry.ts':
          "import v from './dep';\nglobalThis.E = v;\nglobalThis.r = () => import('./Route');",
      },
      'Route.ts',
    );
    expect(exports.default).toBe('ALIASED');
  });

  // 혼합: 같은 lazy 청크에서 cross-chunk re-export(default+named) + 자체 local export 공존.
  // 예약어 default 바인딩과 일반 심볼이 한 destructuring/네임스페이스에 섞여도 정확.
  test('lock: 혼합 lazy 청크 — re-export {default,named} from cjs + 자체 local export 공존', async () => {
    const { exports } = await loadDevSplitLazy(
      {
        'cjslib.js': "module.exports = function(){ return 'MD'; };\nmodule.exports.named = 9;",
        'Route.ts':
          "export { default, named } from './cjslib.js';\nexport const own = 'OWN';\nexport function r(){ return 'R'; }",
        'entry.ts':
          "import l from './cjslib.js';\nglobalThis.E = l;\nglobalThis.r = () => import('./Route');",
      },
      'Route.ts',
    );
    expect((exports.default as () => string)()).toBe('MD');
    expect(exports.named).toBe(9);
    expect(exports.own).toBe('OWN');
    expect((exports.r as () => string)()).toBe('R');
  });

  // follow-up A: cross-chunk ESM *const* named export 가 lazy 청크에서 실값이어야 한다.
  // entry 청크가 dep 를 hoist 하지만, dep 의 const 초기화(`tag="TVAL"`)가 cross-chunk export
  // 스냅샷(`exports.tag = tag`)보다 늦게 돌면 undefined 를 캡처했다(함수는 hoisting 으로 정상,
  // const 만 실패). dev_split user-entry 청크가 hoisted dep wrapped 모듈을 cross-chunk export
  // *앞* 에서 선-init 하도록 수정.
  test('lock: cross-chunk ESM const named export 가 lazy 청크에서 실값 (snapshot 순서 #A)', async () => {
    const { exports } = await loadDevSplitLazy(
      {
        'dep.ts': "export const tag = 'TVAL';\nexport function mk(){ return 'MK'; }",
        'Route.ts':
          "import { tag, mk } from './dep';\nexport function r(){ return tag + ':' + mk(); }",
        'entry.ts':
          "import { mk } from './dep';\nglobalThis.E = mk();\nglobalThis.r = () => import('./Route');",
      },
      'Route.ts',
    );
    expect((exports.r as () => string)()).toBe('TVAL:MK');
  });

  // follow-up B (todo: cross-chunk 네이밍 일관성 = 더 깊은 아키텍처 과제 — 이슈 #4101):
  // 서로 다른 모듈이 *같은* export 이름(`v`)을 내고 한 lazy 청크가 둘 다 import 하면,
  // va·vb 가 같은 값으로 collapse 된다(r()='AA', 'AB' 아님). dep 청크는 renamer deconflict 로
  // 양쪽(`exports.v`/`exports.v$1`)을 노출하고, imports_from dedup 을 (이름,canonical모듈)로
  // 고치면 destructuring(`const {v, v$1}`)·바인딩까지는 맞출 수 있다. 그러나 소비자 **본문**
  // 참조(`return va + vb`)는 codegen 이 cross-chunk 심볼을 *export 명*(`v`)으로 렌더한다 —
  // provider 청크의 deconflict 된 `v$1` 을 모른다(rename_table 이 청크별로 clear 됨). 본문
  // 참조와 destructuring 바인딩을 일치시키려면 cross-chunk 심볼명을 전역 일관되게 유지해야
  // 하고(provider 의 deconflict 된 이름 persistence), 그건 RFC_GRAPH_PERSISTENCE(CLOSED) /
  // lifecycle scope redesign 급 변경이다. 부분 수정은 본문이 여전히 붕괴해 순효과가 없어
  // 보류 — 전역 네이밍 일관성 확보 후 `test.todo`→`test` 로 전환.
  test('다른 모듈의 같은 이름 export 둘을 한 lazy 청크가 import (dedup 붕괴 #B)', async () => {
    const { exports } = await loadDevSplitLazy(
      {
        'a.ts': "export const v = 'A';",
        'b.ts': "export const v = 'B';",
        'Route.ts':
          "import { v as va } from './a';\nimport { v as vb } from './b';\nexport function r(){ return va + vb; }",
        'entry.ts':
          "import { v as va } from './a';\nimport { v as vb } from './b';\nglobalThis.E = va + vb;\nglobalThis.r = () => import('./Route');",
      },
      'Route.ts',
    );
    expect((exports.r as () => string)()).toBe('AB');
  });

  // follow-up (#2): lazy 청크가 `export * from './inner'`(star) 로 다른 청크의 export 를
  // 재노출하면, Route 의 네임스페이스(`exports_Route`)는 getter 로 ia/ib 를 갖지만 청크
  // 수준 노출(`exports.x = exports_Route.x`)이 re_export_star 를 skip 해 동적 청크 exports
  // 에서 ia/ib 가 누락됐다(`import('./Route').ia`=undefined). collectExportsRecursive 로
  // star 전개 이름까지 노출.
  test('lock: lazy 청크의 cross-chunk export *(star) 재노출 (#2)', async () => {
    const { exports } = await loadDevSplitLazy(
      {
        'inner.ts': "export const ia = 'IA';\nexport const ib = 'IB';",
        'Route.ts': "export * from './inner';\nexport const pv = 'PV';",
        'entry.ts':
          "import { ia } from './inner';\nglobalThis.E = ia;\nglobalThis.r = () => import('./Route');",
      },
      'Route.ts',
    );
    expect(exports.ia).toBe('IA'); // star 재노출
    expect(exports.ib).toBe('IB'); // star 재노출
    expect(exports.pv).toBe('PV'); // 자체 export
  });
});
