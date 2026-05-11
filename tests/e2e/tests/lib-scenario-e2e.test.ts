import { test, expect } from '@playwright/test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { serve, closeServer } from './serve';

/**
 * 실제 앱 시나리오로 외부 라이브러리 호환성 매트릭스 검증.
 *
 * browser-smoke.test.ts 는 단일 라이브러리 import → console.log 한 줄 검증.
 * 본 파일은 한 fixture 안에 여러 라이브러리를 조합한 작은 앱을 만들고, DOM 으로
 * 결과를 노출해 playwright 가 `getByTestId` 로 검증한다. ESM/CJS/UMD 혼재,
 * tree-shaking, side-effect, JSX/decorator 등 다양한 시나리오를 추가하기 위한 슬롯.
 *
 * 각 case 는 자체 caseDir (tmpdir) 에서 `npm install` → root 의 lockfile 영향 없음.
 * 서버는 동적 port (`listen(0)`) — 파일/test 간 port 충돌 없음.
 */

const ZNTC_BIN = resolve(__dirname, '../../../zig-out/bin/zntc');

type Scenario = {
  name: string;
  category: string;
  packages: string[];
  entry: string;
  entryFile?: string;
  /** entry 외 추가 fixture 파일. `mkdir -p` + writeFile 처리. */
  files?: Record<string, string>;
  expect: Record<string, string>;
  extraArgs?: string[];
};

const SCENARIOS: Scenario[] = [
  {
    name: 'A1_data_utils_combo',
    category: 'A_esm_data_utils',
    packages: ['lodash-es', 'ramda', 'immer', 'immutable', 'just-pick'],
    entry: `import { sortBy } from 'lodash-es';
import * as R from 'ramda';
import { produce } from 'immer';
import { Map as IMap } from 'immutable';
import pick from 'just-pick';

type Item = { id: number; name: string; tags: string[] };
const items: Item[] = [
  { id: 3, name: 'b', tags: ['x', 'y'] },
  { id: 1, name: 'a', tags: ['y'] },
  { id: 2, name: 'c', tags: ['x', 'z'] },
];

const sortedNames = sortBy(items, 'name').map((i) => i.name).join('');

const uniqTags = R.pipe(
  R.chain((i: Item) => i.tags),
  R.uniq,
  (arr: string[]) => arr.slice().sort().join(''),
)(items);

const next = produce(items[0], (d) => { d.name = 'B'; });
const immerOut = items[0].name + next.name;

const m = IMap({ x: 1 }).set('y', 2);
const immutableOut = String((m.get('x') as number) + (m.get('y') as number));

const picked = pick(items[0], ['id', 'name']);
const pickOut = String(picked.id) + picked.name;

document.body.innerHTML = \`
  <p data-testid="lodash">\${sortedNames}</p>
  <p data-testid="ramda">\${uniqTags}</p>
  <p data-testid="immer">\${immerOut}</p>
  <p data-testid="immutable">\${immutableOut}</p>
  <p data-testid="just">\${pickOut}</p>
\`;
`,
    expect: {
      lodash: 'abc',
      ramda: 'xyz',
      immer: 'bB',
      immutable: '3',
      just: '3b',
    },
  },
  {
    name: 'B1_date_number_combo',
    category: 'B_date_number',
    packages: ['date-fns', 'dayjs', 'luxon', 'big.js', 'decimal.js', 'ms'],
    entry: `import { format } from 'date-fns';
import dayjs from 'dayjs';
import { DateTime } from 'luxon';
import Big from 'big.js';
import Decimal from 'decimal.js';
import ms from 'ms';

const d = new Date(2026, 0, 15);

const datefnsOut = format(d, 'yyyy-MM-dd');
const dayjsOut = dayjs(d).format('YYYY-MM-DD');
const luxonOut = DateTime.fromJSDate(d).toFormat('yyyy-MM-dd');
const bigOut = new Big(0.1).plus(0.2).toFixed(1);
const decimalOut = new Decimal(0.1).plus(0.2).toFixed(1);
const msOut = String(ms('1.5h'));

document.body.innerHTML = \`
  <p data-testid="datefns">\${datefnsOut}</p>
  <p data-testid="dayjs">\${dayjsOut}</p>
  <p data-testid="luxon">\${luxonOut}</p>
  <p data-testid="big">\${bigOut}</p>
  <p data-testid="decimal">\${decimalOut}</p>
  <p data-testid="ms">\${msOut}</p>
\`;
`,
    expect: {
      datefns: '2026-01-15',
      dayjs: '2026-01-15',
      luxon: '2026-01-15',
      big: '0.3',
      decimal: '0.3',
      ms: '5400000',
    },
  },
  {
    name: 'C1_react_state_combo',
    category: 'C_react_state',
    packages: ['react', 'react-dom', 'zustand', 'jotai', 'valtio'],
    entryFile: 'index.tsx',
    extraArgs: ['--jsx=automatic'],
    entry: `import { createRoot } from 'react-dom/client';
import { create } from 'zustand';
import { atom, useAtom } from 'jotai';
import { proxy, useSnapshot } from 'valtio';

const useStore = create<{ n: number }>(() => ({ n: 42 }));
const aAtom = atom('jotai-ok');
const vState = proxy({ msg: 'valtio-ok' });

function App() {
  const n = useStore((s) => s.n);
  const [a] = useAtom(aAtom);
  const v = useSnapshot(vState);
  return (
    <div>
      <p data-testid="zustand">{n}</p>
      <p data-testid="jotai">{a}</p>
      <p data-testid="valtio">{v.msg}</p>
    </div>
  );
}

const mount = document.createElement('div');
document.body.appendChild(mount);
createRoot(mount).render(<App />);
`,
    expect: {
      zustand: '42',
      jotai: 'jotai-ok',
      valtio: 'valtio-ok',
    },
  },
  {
    name: 'D1_validation_serialize_combo',
    category: 'D_validation_serialize',
    packages: ['zod', 'yup', 'valibot', 'superjson', 'json5', 'devalue'],
    entry: `import { z } from 'zod';
import * as yup from 'yup';
import * as v from 'valibot';
import superjson from 'superjson';
import JSON5 from 'json5';
import { stringify as devalueStringify } from 'devalue';

const zodOk = z.object({ x: z.number() }).safeParse({ x: 7 }).success ? 'ok' : 'fail';
const yupOk = yup.object({ x: yup.number().required() }).isValidSync({ x: 7 }) ? 'ok' : 'fail';
const valOk = v.is(v.object({ x: v.number() }), { x: 7 }) ? 'ok' : 'fail';
const superjsonOk = superjson.stringify({ d: new Date('2026-01-15') }).includes('Date') ? 'ok' : 'fail';
const json5Out = JSON.stringify(JSON5.parse('{a: 1, /* c */ b: 2,}'));
const cyclic: { a: number; self?: unknown } = { a: 1 };
cyclic.self = cyclic;
const devalueOk = devalueStringify(cyclic).length > 5 ? 'ok' : 'fail';

document.body.innerHTML = \`
  <p data-testid="zod">\${zodOk}</p>
  <p data-testid="yup">\${yupOk}</p>
  <p data-testid="valibot">\${valOk}</p>
  <p data-testid="superjson">\${superjsonOk}</p>
  <p data-testid="json5">\${json5Out}</p>
  <p data-testid="devalue">\${devalueOk}</p>
\`;
`,
    expect: {
      zod: 'ok',
      yup: 'ok',
      valibot: 'ok',
      superjson: 'ok',
      json5: '{"a":1,"b":2}',
      devalue: 'ok',
    },
  },
  {
    name: 'E1_reactive_stream_combo',
    category: 'E_reactive_stream',
    packages: ['rxjs', 'mitt', 'eventemitter3', 'nanostores', 'xstate'],
    entry: `import { of, reduce } from 'rxjs';
import mitt from 'mitt';
import EE from 'eventemitter3';
import { atom } from 'nanostores';
import { createMachine, createActor } from 'xstate';

let rxjsOut = 'fail';
of(1, 2, 3).pipe(reduce((a, b) => a + b, 0)).subscribe((v) => { rxjsOut = String(v); });

let mittOut = 'fail';
const m = mitt<{ ping: number }>();
m.on('ping', (n) => { mittOut = String(n); });
m.emit('ping', 42);

let eeOut = 'fail';
const ee = new EE();
ee.on('go', (n: number) => { eeOut = String(n); });
ee.emit('go', 99);

let nanoOut = 'fail';
const a = atom(0);
a.subscribe((v) => { nanoOut = String(v); });
a.set(7);

const machine = createMachine({
  id: 'toggle',
  initial: 'off',
  states: {
    off: { on: { TOGGLE: 'on' } },
    on: { on: { TOGGLE: 'off' } },
  },
});
const actor = createActor(machine).start();
actor.send({ type: 'TOGGLE' });
const xstateOut = String(actor.getSnapshot().value);

document.body.innerHTML = \`
  <p data-testid="rxjs">\${rxjsOut}</p>
  <p data-testid="mitt">\${mittOut}</p>
  <p data-testid="eventemitter3">\${eeOut}</p>
  <p data-testid="nanostores">\${nanoOut}</p>
  <p data-testid="xstate">\${xstateOut}</p>
\`;
`,
    expect: {
      rxjs: '6',
      mitt: '42',
      eventemitter3: '99',
      nanostores: '7',
      xstate: 'on',
    },
  },
  {
    name: 'F1_network_rpc_combo',
    category: 'F_network_rpc',
    packages: ['axios', 'ky', 'hono', 'comlink', 'eventsource-parser'],
    entry: `import axios from 'axios';
import ky from 'ky';
import { hc } from 'hono/client';
import * as Comlink from 'comlink';
import { createParser } from 'eventsource-parser';

const ax = axios.create({ baseURL: 'https://api.example.com' });
const axiosOut = ax.defaults.baseURL === 'https://api.example.com' ? 'ok' : 'fail';
const kyOut = typeof ky === 'function' ? 'ok' : 'fail';
const honoOut = typeof hc === 'function' ? 'ok' : 'fail';
const comlinkOut = typeof Comlink.wrap === 'function' ? 'ok' : 'fail';

const events: string[] = [];
const parser = createParser({
  onEvent: (e: { data: string }) => { events.push(e.data); },
});
parser.feed('data: hello\\n\\n');
parser.feed('data: world\\n\\n');
const sseOut = events.join('+');

document.body.innerHTML = \`
  <p data-testid="axios">\${axiosOut}</p>
  <p data-testid="ky">\${kyOut}</p>
  <p data-testid="hono">\${honoOut}</p>
  <p data-testid="comlink">\${comlinkOut}</p>
  <p data-testid="sse">\${sseOut}</p>
\`;
`,
    expect: {
      axios: 'ok',
      ky: 'ok',
      hono: 'ok',
      comlink: 'ok',
      sse: 'hello+world',
    },
  },
  {
    name: 'G1_legacy_cjs_combo',
    category: 'G_legacy_cjs',
    packages: ['moment', 'underscore', 'async', 'q', 'classnames', 'bluebird'],
    entry: `import moment from 'moment';
import _ from 'underscore';
import async from 'async';
import Q from 'q';
import cn from 'classnames';
import BBPromise from 'bluebird';

const results: Record<string, string> = {
  moment: 'fail',
  underscore: 'fail',
  async: 'fail',
  q: 'fail',
  classnames: 'fail',
  bluebird: 'fail',
};

results.moment = moment('2026-01-15').format('YYYY-MM-DD');
results.underscore = _.map([1, 2, 3], (n: number) => n * 2).join('');
results.classnames = cn('a', { b: true, c: false }, ['d']);

function render() {
  document.body.innerHTML = \`
    <p data-testid="moment">\${results.moment}</p>
    <p data-testid="underscore">\${results.underscore}</p>
    <p data-testid="async">\${results.async}</p>
    <p data-testid="q">\${results.q}</p>
    <p data-testid="classnames">\${results.classnames}</p>
    <p data-testid="bluebird">\${results.bluebird}</p>
  \`;
}
render();

async.parallel(
  [
    (cb: (err: unknown, v: string) => void) => cb(null, 'a'),
    (cb: (err: unknown, v: string) => void) => cb(null, 'b'),
  ],
  (_err: unknown, vals: string[]) => {
    results.async = vals.join('');
    render();
  },
);

Q('q-ok').then((v: string) => {
  results.q = v;
  render();
});

BBPromise.resolve('bb-ok').then((v: string) => {
  results.bluebird = v;
  render();
});
`,
    expect: {
      moment: '2026-01-15',
      underscore: '246',
      async: 'ab',
      q: 'q-ok',
      classnames: 'a b d',
      bluebird: 'bb-ok',
    },
  },
  {
    // 회귀 테스트 — #3068 helper scope 격리: 사용자가 `_jsx` 식별자를 의도적으로
    // 선언한 경우에도 JSX runtime call 이 사용자 binding 으로 잘못 묶이지 않아야 한다.
    // 사용자 함수 `_jsx` (`user-jsx-...` 반환) 와 JSX call 결과 (`<p>JSX-ok</p>`) 가
    // 모두 자기 의도대로 동작하는지 검증.
    name: 'H4_preact_jsx_user_id_collision',
    category: 'H_jsx_ts',
    packages: ['preact'],
    entryFile: 'index.tsx',
    extraArgs: ['--jsx=automatic', '--jsx-import-source=preact'],
    entry: `import { render } from 'preact';

const _jsx = (msg: string) => \`user-jsx-\${msg}\`;
const userOut = _jsx('hi');

function App() {
  return <p data-testid="jsx">JSX-ok</p>;
}

const mount = document.createElement('div');
document.body.appendChild(mount);
render(<App />, mount);

const userP = document.createElement('p');
userP.setAttribute('data-testid', 'user');
userP.textContent = userOut;
document.body.appendChild(userP);
`,
    expect: {
      jsx: 'JSX-ok',
      user: 'user-jsx-hi',
    },
  },
  {
    // 회귀 테스트 — #3062 (`--jsx=automatic --jsx-import-source=preact`):
    // transformer 가 JSX runtime import 를 정식 AST 노드로 추가하지 않고 parser_metadata
    // 가 synthetic ImportRecord/Binding 만 inject 하던 우회 경로 때문에, ESM
    // (wrap_kind=.none) source 의 canonical 식별자와 entry 의 `_jsx` 가 alias 안 되어
    // `ReferenceError: _jsx is not defined` 발생했다. fix 이후 transformer 가 직접
    // import_declaration 노드를 prepend 하면 다운스트림이 일반 import 로 처리한다.
    name: 'H1_preact_jsx_automatic',
    category: 'H_jsx_ts',
    packages: ['preact'],
    entryFile: 'index.tsx',
    extraArgs: ['--jsx=automatic', '--jsx-import-source=preact'],
    entry: `import { render } from 'preact';

function App() {
  return <p data-testid="preact">preact-ok</p>;
}

const mount = document.createElement('div');
document.body.appendChild(mount);
render(<App />, mount);
`,
    expect: {
      preact: 'preact-ok',
    },
  },
  {
    // 회귀 테스트 — JSX element 의 static children 여러 개 → `_jsxs` 사용 경로.
    // automatic transform 의 callee 분기 (`_jsx` vs `_jsxs`) 가 helper marker 와
    // 함께 정상 동작하는지 검증.
    name: 'H7_preact_jsx_static_children',
    category: 'H_jsx_ts',
    packages: ['preact'],
    entryFile: 'index.tsx',
    extraArgs: ['--jsx=automatic', '--jsx-import-source=preact'],
    entry: `import { render } from 'preact';

function App() {
  return (
    <div>
      <span data-testid="c1">one</span>
      <span data-testid="c2">two</span>
      <span data-testid="c3">three</span>
    </div>
  );
}

const mount = document.createElement('div');
document.body.appendChild(mount);
render(<App />, mount);
`,
    expect: {
      c1: 'one',
      c2: 'two',
      c3: 'three',
    },
  },
  {
    // 회귀 테스트 — JSX fragment (`<>...</>`) + static children → `_jsxs(_Fragment, ...)`.
    // _Fragment helper ref 도 marker 를 거치는지 검증.
    name: 'H8_preact_jsx_fragment_static',
    category: 'H_jsx_ts',
    packages: ['preact'],
    entryFile: 'index.tsx',
    extraArgs: ['--jsx=automatic', '--jsx-import-source=preact'],
    entry: `import { render } from 'preact';

function App() {
  return (
    <>
      <span data-testid="f1">alpha</span>
      <span data-testid="f2">beta</span>
    </>
  );
}

const mount = document.createElement('div');
document.body.appendChild(mount);
render(<App />, mount);
`,
    expect: {
      f1: 'alpha',
      f2: 'beta',
    },
  },
  {
    // 회귀 테스트 — #1209: JSX 컴포넌트를 require() 로 소비하면 그 모듈이 ESM-wrapped
    // (__esm init 함수) 로 강제된다. helper marker binding (`_jsx` 등) 이 top-level 로
    // hoist 되지 않으면 init 함수 안의 `var _jsx = ...` 가 호이스팅된 컴포넌트 함수에서
    // 접근 불가 → `_jsx is not a function`. esm_wrap 의 hoist loop 가 is_helper binding
    // 을 처리하는지 검증.
    name: 'H9_preact_jsx_esm_wrapped',
    category: 'H_jsx_ts',
    packages: ['preact'],
    entryFile: 'index.ts',
    extraArgs: ['--jsx=automatic', '--jsx-import-source=preact'],
    files: {
      // .tsx 모듈을 require() 로 소비 → ESM-wrap 강제
      'Comp.tsx': `import { render } from 'preact';\nexport function mountComp() {\n  const m = document.createElement('div');\n  document.body.appendChild(m);\n  render(<p data-testid="esm">esm-wrapped-ok</p>, m);\n}\n`,
    },
    entry: `const { mountComp } = require('./Comp.tsx');
mountComp();
`,
    expect: {
      esm: 'esm-wrapped-ok',
    },
  },
  {
    name: 'H2_vue_h_render',
    category: 'H_jsx_ts',
    packages: ['vue'],
    entry: `import { createApp, h } from 'vue';

const mount = document.createElement('div');
document.body.appendChild(mount);
createApp({
  render: () => h('p', { 'data-testid': 'vue' }, 'vue-ok'),
}).mount(mount);
`,
    expect: {
      vue: 'vue-ok',
    },
  },
  {
    // 회귀 테스트 — 여러 모듈이 같은 jsx-runtime 을 import 할 때 각 모듈이 독립적으로
    // 정상 emit. 기존 zig test "JSX automatic: multiple modules sharing same jsx-runtime"
    // 의 e2e 대체.
    name: 'H5_preact_jsx_multi_module',
    category: 'H_jsx_ts',
    packages: ['preact'],
    entryFile: 'index.tsx',
    extraArgs: ['--jsx=automatic', '--jsx-import-source=preact'],
    files: {
      'CompA.tsx': `export function CompA() { return <span data-testid="a">A</span>; }\n`,
      'CompB.tsx': `export function CompB() { return <span data-testid="b">B</span>; }\n`,
    },
    entry: `import { render } from 'preact';
import { CompA } from './CompA';
import { CompB } from './CompB';

function App() {
  return <div><CompA /><CompB /></div>;
}

const mount = document.createElement('div');
document.body.appendChild(mount);
render(<App />, mount);
`,
    expect: {
      a: 'A',
      b: 'B',
    },
  },
  {
    // 회귀 테스트 — JSX 컴포넌트 re-export (barrel 파일) 통과 후 정상 emit. 기존 zig
    // test "JSX automatic: re-export of JSX component" 의 e2e 대체.
    name: 'H6_preact_jsx_re_export',
    category: 'H_jsx_ts',
    packages: ['preact'],
    entryFile: 'index.tsx',
    extraArgs: ['--jsx=automatic', '--jsx-import-source=preact'],
    files: {
      'Button.tsx': `export function Button() { return <button data-testid="btn">Click</button>; }\n`,
      'barrel.ts': `export { Button } from './Button';\n`,
    },
    entry: `import { render } from 'preact';
import { Button } from './barrel';

function App() {
  return <div><Button /></div>;
}

const mount = document.createElement('div');
document.body.appendChild(mount);
render(<App />, mount);
`,
    expect: {
      btn: 'Click',
    },
  },
  {
    // 회귀 테스트 — IIFE format + JSX automatic. IIFE 는 ESM `import` 가 불가하므로
    // transformer 가 추가한 jsx-runtime import 노드가 chunk top 의 `import` 가 아니라
    // 번들 안에 inline 합쳐져야 한다 (preact/jsx-runtime 모듈이 IIFE wrapper 내부).
    name: 'H10_preact_jsx_iife',
    category: 'H_jsx_ts',
    packages: ['preact'],
    entryFile: 'index.tsx',
    extraArgs: ['--format=iife', '--jsx=automatic', '--jsx-import-source=preact'],
    entry: `import { render } from 'preact';

function App() {
  return <p data-testid="iife">iife-jsx-ok</p>;
}

const mount = document.createElement('div');
document.body.appendChild(mount);
render(<App />, mount);
`,
    expect: {
      iife: 'iife-jsx-ok',
    },
  },
  {
    name: 'H3_ts_legacy_decorator',
    category: 'H_jsx_ts',
    packages: [],
    extraArgs: ['--experimental-decorators'],
    entry: `function Tag(value: string) {
  return function (target: { tag?: string }) {
    target.tag = value;
  };
}

@Tag('decorated')
class Foo {
  static tag: string | undefined;
}

document.body.innerHTML = \`<p data-testid="decorator">\${Foo.tag}</p>\`;
`,
    expect: {
      decorator: 'decorated',
    },
  },
];

test.describe.configure({ mode: 'parallel' });

let fixtureRoot: string;

test.beforeAll(async () => {
  fixtureRoot = await mkdtemp(join(tmpdir(), 'zntc-lib-scenario-'));
});

test.afterAll(async () => {
  await rm(fixtureRoot, { recursive: true, force: true });
});

for (const s of SCENARIOS) {
  test(`${s.category} / ${s.name}`, async ({ page }) => {
    const caseDir = join(fixtureRoot, s.name);
    await mkdir(caseDir, { recursive: true });

    await writeFile(
      join(caseDir, 'package.json'),
      JSON.stringify({ name: `lib-scenario-${s.name}`, private: true }),
    );
    if (s.packages.length > 0) {
      const install = spawnSync(
        'npm',
        ['install', ...s.packages, '--prefer-offline', '--no-audit', '--no-fund', '--no-progress'],
        { cwd: caseDir, stdio: 'pipe', timeout: 180000 },
      );
      expect(
        install.status,
        `npm install ${s.packages.join(' ')} failed: ${install.stderr?.toString().slice(0, 400)}`,
      ).toBe(0);
    }

    const entryFile = s.entryFile ?? 'index.ts';
    await writeFile(join(caseDir, entryFile), s.entry);
    if (s.files) {
      for (const [relPath, content] of Object.entries(s.files)) {
        const filePath = join(caseDir, relPath);
        const dir = dirname(filePath);
        if (dir !== caseDir) await mkdir(dir, { recursive: true });
        await writeFile(filePath, content);
      }
    }
    const outFile = join(caseDir, 'bundle.js');
    const build = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(caseDir, entryFile),
        '-o',
        outFile,
        '--platform=browser',
        ...(s.extraArgs ?? []),
      ],
      { stdio: 'pipe', timeout: 60000 },
    );
    expect(
      build.status,
      `zntc build failed for ${s.name}: ${build.stderr?.toString().slice(0, 600)}`,
    ).toBe(0);

    await writeFile(
      join(caseDir, 'index.html'),
      `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body><script src="./bundle.js"></script></body></html>`,
    );

    const { server, port } = await serve(caseDir);
    try {
      const errors: string[] = [];
      page.on('pageerror', (err) => errors.push(err.message));

      await page.goto(`http://localhost:${port}/`);

      for (const [testid, expectedText] of Object.entries(s.expect)) {
        await expect(page.getByTestId(testid), `${s.name}: data-testid="${testid}"`).toHaveText(
          expectedText,
        );
      }

      expect(errors, `${s.name} browser errors: ${errors.join('; ')}`).toHaveLength(0);
    } finally {
      await closeServer(server);
    }
  });
}
