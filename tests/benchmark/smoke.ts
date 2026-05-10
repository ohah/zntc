#!/usr/bin/env bun
/**
 * ZNTC Smoke Test — 실제 프로젝트 빌드+실행 검증
 *
 * npm에서 실제 라이브러리를 설치하고 ZNTC/esbuild/rolldown으로 번들링하여
 * 1) 빌드 성공  2) 실행 성공  3) 출력 일치 여부를 비교한다.
 *
 * esbuild 출력을 기준(baseline)으로 ZNTC/rolldown 출력이 동일한지 검증.
 */

import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync, rmSync, existsSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(__dirname, '../..');
const ZNTC_BIN = join(ROOT, 'zig-out/bin/zntc');
// bun workspace hoisting: devDependencies가 루트 node_modules에 설치될 수 있음
const ESBUILD_BIN = existsSync(join(__dirname, 'node_modules/.bin/esbuild'))
  ? join(__dirname, 'node_modules/.bin/esbuild')
  : join(ROOT, 'node_modules/.bin/esbuild');
const ROLLDOWN_BIN = existsSync(join(__dirname, 'node_modules/.bin/rolldown'))
  ? join(__dirname, 'node_modules/.bin/rolldown')
  : join(ROOT, 'node_modules/.bin/rolldown');
const RSPACK_BIN = existsSync(join(__dirname, 'node_modules/.bin/rspack'))
  ? join(__dirname, 'node_modules/.bin/rspack')
  : join(ROOT, 'node_modules/.bin/rspack');

export interface BundlerResult {
  build: boolean;
  size: number;
  time: number;
  stdout: string;
  outputPath?: string;
  buildArgs?: string[];
  stderrSummary?: string;
}

export interface SmokeResult {
  project: string;
  zntc: BundlerResult;
  esbuild: BundlerResult;
  rolldown: BundlerResult;
  rspack: BundlerResult;
  outputMatch: boolean;
  errors: string[];
}

function exec(
  bin: string,
  args: string[],
  cwd?: string,
): { ok: boolean; stdout: string; stderr: string; time: number } {
  const start = performance.now();
  const r = spawnSync(bin, args, { cwd, stdio: 'pipe', timeout: 120000 });
  const time = Math.round(performance.now() - start);
  const stdout = r.stdout?.toString().trim() ?? '';
  const stderr = r.stderr?.toString() ?? '';
  return { ok: r.status === 0, stdout, stderr, time };
}

function fileSize(path: string): number {
  try {
    return statSync(path).size;
  } catch {
    return 0;
  }
}

const emptyResult: BundlerResult = {
  build: false,
  size: 0,
  time: 0,
  stdout: '',
  outputPath: '',
  buildArgs: [],
  stderrSummary: '',
};

interface SmokeOptions {
  keepOutputDir?: string;
  deep?: boolean;
  /** 모든 fixture 에 minify 강제. fixture 의 minify=false 도 override 한다. */
  forceMinify?: boolean;
  /** 모든 fixture 를 CJS 빌드로 시도. 일부 ESM-only 라이브러리는 빌드 실패할 수 있음. */
  forceCjs?: boolean;
}

function stderrSummary(stderr: string): string {
  return stderr
    .trim()
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, 8)
    .join('\n')
    .slice(0, 1000);
}

/** 단일 번들러로 빌드 + 실행하고 결과 반환 */
function bundleAndRun(
  bin: string,
  buildArgs: string[],
  outFile: string,
  cwd?: string,
): BundlerResult {
  const build = exec(bin, buildArgs, cwd);
  if (!build.ok) {
    return {
      build: false,
      size: 0,
      time: build.time,
      stdout: '',
      outputPath: outFile,
      buildArgs,
      stderrSummary: stderrSummary(build.stderr),
    };
  }
  const run = exec('node', [outFile]);
  return {
    build: run.ok,
    size: fileSize(outFile),
    time: build.time,
    stdout: run.ok ? run.stdout : '',
    outputPath: outFile,
    buildArgs,
    stderrSummary: stderrSummary(build.stderr || run.stderr),
  };
}

interface ProjectConfig {
  name: string;
  pkg: string;
  entry: string;
  /**
   * `entry` 를 완전히 대체한다 (extend 가 아님). 라이브러리 내부 코드 path 를
   * 실제로 깨워서 트리쉐이커가 잘못 잘라낸 코드를 런타임 에러로 드러내는 게 목적.
   */
  deepEntry?: string;
  files?: Record<string, string>;
  external?: string[];
  format?: 'esm' | 'cjs';
  platform?: 'node' | 'browser';
  tsconfig?: Record<string, boolean>;
  target?: string; // --target=es5, --target=es2015, etc.
  minify?: boolean; // --minify 전파 (ZNTC/esbuild/rolldown/rspack 공통)
  production?: boolean; // rspack mode=production과 동일한 NODE_ENV define 적용 여부
}

function isProductionBuild(p: ProjectConfig): boolean {
  return p.production ?? true;
}

function testProject(p: ProjectConfig, options: SmokeOptions = {}): SmokeResult {
  const dir = options.keepOutputDir
    ? join(options.keepOutputDir, p.name)
    : mkdtempSync(join(tmpdir(), `zntc-smoke-${p.name}-`));
  if (options.keepOutputDir) {
    rmSync(dir, { recursive: true, force: true });
    mkdirSync(dir, { recursive: true });
  }
  const result: SmokeResult = {
    project: p.name,
    zntc: { ...emptyResult },
    esbuild: { ...emptyResult },
    rolldown: { ...emptyResult },
    rspack: { ...emptyResult },
    outputMatch: false,
    errors: [],
  };

  // entry 파일을 benchmark 디렉토리에 작성 (node_modules resolve를 위해)
  const entryFile = join(__dirname, `_smoke_entry_${p.name}.ts`);
  const extraFiles: string[] = [];
  try {
    const activeEntry = options.deep && p.deepEntry ? p.deepEntry : p.entry;
    writeFileSync(entryFile, activeEntry);
    if (p.files) {
      for (const [relativePath, content] of Object.entries(p.files)) {
        const filePath = join(__dirname, relativePath);
        mkdirSync(dirname(filePath), { recursive: true });
        writeFileSync(filePath, content);
        extraFiles.push(filePath);
      }
    }

    // tsconfig.json 생성 (decorator 등 옵션이 필요한 경우)
    const tsconfigFile = join(__dirname, `_smoke_tsconfig_${p.name}.json`);
    if (p.tsconfig) {
      writeFileSync(tsconfigFile, JSON.stringify({ compilerOptions: p.tsconfig }));
    }

    const zntcOut = join(dir, 'dist-zntc.js');
    const esOut = join(dir, 'dist-esbuild.js');
    const rdOut = join(dir, 'dist-rolldown.js');
    const ext = p.external ?? [];
    const format = options.forceCjs ? 'cjs' : (p.format ?? 'esm');
    const platform = p.platform ?? 'node';
    const production = isProductionBuild(p);
    const nodeEnvDefine = production ? `"production"` : `"development"`;
    const minify = options.forceMinify || !!p.minify;

    // ZNTC
    const zntcExternalArgs = ext.flatMap((e) => ['--external', e]);
    const zntcFormatArgs = format === 'cjs' ? ['--format=cjs'] : [];
    const zntcTsconfigArgs = p.tsconfig ? ['-p', tsconfigFile] : [];
    const zntcTargetArgs = p.target ? [`--target=${p.target}`] : [];
    const zntcMinifyArgs = minify ? ['--minify'] : [];
    const zntcDefineArgs = [`--define:process.env.NODE_ENV=${nodeEnvDefine}`];
    result.zntc = bundleAndRun(
      ZNTC_BIN,
      [
        '--bundle',
        entryFile,
        '-o',
        zntcOut,
        `--platform=${platform}`,
        ...zntcExternalArgs,
        ...zntcFormatArgs,
        ...zntcTsconfigArgs,
        ...zntcTargetArgs,
        ...zntcMinifyArgs,
        ...zntcDefineArgs,
      ],
      zntcOut,
    );
    if (!result.zntc.build && result.zntc.size === 0) {
      result.errors.push(`ZNTC: build or run failed`);
    }

    // esbuild
    if (existsSync(ESBUILD_BIN)) {
      const esExternalArgs = ext.flatMap((e) => [`--external:${e}`]);
      const esFormatArgs = format === 'esm' ? [`--format=esm`] : [];
      const esTargetArgs = p.target ? [`--target=${p.target}`] : [];
      const esMinifyArgs = minify ? ['--minify'] : [];
      const esDefineArgs = [`--define:process.env.NODE_ENV=${nodeEnvDefine}`];
      result.esbuild = bundleAndRun(
        ESBUILD_BIN,
        [
          entryFile,
          '--bundle',
          `--outfile=${esOut}`,
          '--loader:.ts=ts',
          `--platform=${platform}`,
          ...esExternalArgs,
          ...esFormatArgs,
          ...esTargetArgs,
          ...esMinifyArgs,
          ...esDefineArgs,
        ],
        esOut,
        __dirname,
      );
      if (!result.esbuild.build) {
        result.errors.push(`esbuild: build or run failed`);
      }
    }

    // rolldown
    if (existsSync(ROLLDOWN_BIN)) {
      const rdExternalArgs = ext.flatMap((e) => ['--external', e]);
      const rdMinifyArgs = minify ? ['--minify'] : [];
      const rdDefineArgs = ['--transform.define', `process.env.NODE_ENV:${nodeEnvDefine}`];
      result.rolldown = bundleAndRun(
        ROLLDOWN_BIN,
        [
          entryFile,
          '-o',
          rdOut,
          '--format',
          format,
          '--platform',
          platform,
          ...rdExternalArgs,
          ...rdMinifyArgs,
          ...rdDefineArgs,
        ],
        rdOut,
        __dirname,
      );
      if (!result.rolldown.build) {
        result.errors.push(`rolldown: build or run failed`);
      }
    }

    // rspack (config 파일 생성 — CLI만으로는 target/externals 설정 불가)
    if (existsSync(RSPACK_BIN) && !p.target) {
      const rsOut = join(dir, 'dist-rspack');
      const rsConfigPath = join(__dirname, `_rspack_config_${p.name}.cjs`);
      const rsConfig = `module.exports = {
        entry: ${JSON.stringify(entryFile)},
        output: { path: ${JSON.stringify(rsOut)}, filename: "main.js" },
        target: ${JSON.stringify(platform === 'node' ? 'node' : 'web')},
        mode: ${JSON.stringify(production ? 'production' : 'development')},
        optimization: { minimize: ${minify ? 'true' : 'false'} },
        module: { rules: [{ test: /\\.ts$/, use: { loader: "builtin:swc-loader", options: { jsc: { parser: { syntax: "typescript" } } } } }] },
        ${ext.length > 0 ? `externals: ${JSON.stringify(ext)},` : ''}
      };`;
      writeFileSync(rsConfigPath, rsConfig);
      result.rspack = bundleAndRun(
        RSPACK_BIN,
        ['build', '-c', rsConfigPath],
        join(rsOut, 'main.js'),
        __dirname,
      );
      try {
        rmSync(rsConfigPath);
      } catch {}
      if (!result.rspack.build) {
        result.errors.push(`rspack: build or run failed`);
      }
    }

    // 출력 비교: esbuild를 baseline으로
    if (result.zntc.build && result.esbuild.build) {
      result.outputMatch = result.zntc.stdout === result.esbuild.stdout;
      if (!result.outputMatch) {
        result.errors.push(
          `Output mismatch:\n  ZNTC:     ${result.zntc.stdout.slice(0, 100)}\n  esbuild: ${result.esbuild.stdout.slice(0, 100)}`,
        );
      }
    } else if (result.zntc.build && result.rolldown.build) {
      // esbuild 실패 시 rolldown과 비교
      result.outputMatch = result.zntc.stdout === result.rolldown.stdout;
      if (!result.outputMatch) {
        result.errors.push(
          `Output mismatch:\n  ZNTC:      ${result.zntc.stdout.slice(0, 100)}\n  rolldown: ${result.rolldown.stdout.slice(0, 100)}`,
        );
      }
    }
  } finally {
    if (!options.keepOutputDir) {
      rmSync(dir, { recursive: true, force: true });
    }
    try {
      rmSync(entryFile);
    } catch {}
    for (const filePath of extraFiles) {
      try {
        rmSync(filePath);
      } catch {}
    }
    try {
      rmSync(tsconfigFile);
    } catch {}
  }

  return result;
}

// ============================================================
// Test cases
// ============================================================

const projects: ProjectConfig[] = [
  {
    name: 'lodash-es',
    pkg: 'lodash-es',
    entry: `import { groupBy, sortBy, uniq } from 'lodash-es';\nconsole.log(groupBy, sortBy, uniq);`,
    deepEntry: `import { groupBy, sortBy, uniq, chunk, flatMap, keyBy, mapValues, pick, omit, debounce } from 'lodash-es';
const arr = [{ c: 'a', n: 1 }, { c: 'b', n: 2 }, { c: 'a', n: 3 }, { c: 'b', n: 4 }, { c: 'a', n: 5 }];
const grouped = groupBy(arr, 'c');
const sorted = sortBy(arr, 'n');
const u = uniq([1, 2, 2, 3, 3, 3]);
const chunked = chunk([1, 2, 3, 4, 5, 6, 7], 3);
const flat = flatMap([1, 2, 3], (n) => [n, n * 10]);
const indexed = keyBy(arr, 'n');
const valued = mapValues(grouped, (list) => list.length);
const picked = pick({ a: 1, b: 2, c: 3 }, ['a', 'c']);
const omitted = omit({ a: 1, b: 2, c: 3 }, ['b']);
const dbg = debounce(() => 0, 100);
console.log(JSON.stringify({
  grouped: Object.keys(grouped).sort(),
  sortedFirst: sorted[0].n,
  uniq: u,
  chunked: chunked.length,
  flat,
  indexedKeys: Object.keys(indexed).sort(),
  valued,
  picked,
  omitted,
  hasDbg: typeof dbg === 'function',
}));`,
  },
  {
    name: 'preact',
    pkg: 'preact',
    entry: `import { h, render } from 'preact';\nconsole.log(h, render);`,
    deepEntry: `import { h, Fragment, Component, cloneElement, createRef, createContext, options } from 'preact';
const el = h('div', { id: 't' }, h('span', null, 'a'), h('span', null, 'b'));
const cloned = cloneElement(el, { 'data-x': '1' });
const ref = createRef();
const ctx = createContext('default');
console.log(JSON.stringify({
  type: el.type,
  id: el.props.id,
  kids: (el.props.children as unknown[]).length,
  cloned: cloned.props['data-x'],
  fragment: typeof Fragment === 'function',
  comp: typeof Component === 'function',
  ref: ref.current === null,
  ctx: typeof ctx.Provider === 'function',
  optsObj: typeof options === 'object',
}));`,
  },
  {
    name: 'date-fns',
    pkg: 'date-fns',
    entry: `import { format, addDays } from 'date-fns';\nconsole.log(format(addDays(new Date(), 1), 'yyyy-MM-dd'));`,
    deepEntry: `import { format, addDays, subDays, differenceInDays, parseISO, isValid, startOfMonth, endOfMonth, addMonths, isAfter } from 'date-fns';
const d = new Date('2024-06-15T00:00:00Z');
const next = addDays(d, 10);
const prev = subDays(d, 5);
const diff = differenceInDays(next, prev);
const parsed = parseISO('2024-12-31');
const valid = isValid(parsed);
const som = startOfMonth(d);
const eom = endOfMonth(d);
const nm = addMonths(d, 1);
const after = isAfter(next, d);
console.log(JSON.stringify({
  next: format(next, 'yyyy-MM-dd'),
  prev: format(prev, 'yyyy-MM-dd'),
  diff,
  parsedYear: parsed.getUTCFullYear(),
  valid,
  som: format(som, 'yyyy-MM-dd'),
  eom: format(eom, 'yyyy-MM-dd'),
  nextMonth: format(nm, 'yyyy-MM-dd'),
  after,
}));`,
  },
  {
    name: 'uuid',
    pkg: 'uuid',
    entry: `import { v4 } from 'uuid';\nconst id = v4();\nconsole.log(typeof id, id.length);`,
  },
  {
    name: 'zod',
    pkg: 'zod',
    entry: `import { z } from 'zod';\nconst schema = z.string().email();\nconsole.log(schema.parse('test@test.com'));`,
    deepEntry: `import { z } from 'zod';
const Schema = z.object({
  name: z.string().min(2),
  age: z.number().int().min(0).max(120),
  email: z.string().email(),
  tags: z.array(z.string()).optional(),
  role: z.enum(['admin', 'user']).default('user'),
});
const Union = z.union([z.literal('a'), z.literal('b')]);
const Tuple = z.tuple([z.string(), z.number()]);
const ok = Schema.safeParse({ name: 'Alice', age: 30, email: 'a@b.com', tags: ['x'] });
const fail = Schema.safeParse({ name: 'A', age: -1, email: 'no' });
const u = Union.safeParse('a');
const t = Tuple.safeParse(['x', 1]);
console.log(JSON.stringify({
  ok: ok.success && ok.data.role === 'user',
  failErrors: !fail.success && fail.error.issues.length >= 2,
  union: u.success && u.data,
  tuple: t.success && JSON.stringify(t.data),
}));`,
  },
  {
    name: 'axios',
    pkg: 'axios',
    entry: `import axios from 'axios';\nconsole.log(typeof axios.get, typeof axios.post, typeof axios.create);`,
    deepEntry: `import axios, { isAxiosError, isCancel, AxiosHeaders, AxiosError } from 'axios';
const inst = axios.create({ baseURL: 'http://x', timeout: 1000, headers: { 'X-Test': '1' } });
const headers = new AxiosHeaders({ 'Content-Type': 'application/json' });
headers.set('X-Y', '2');
const err = new AxiosError('boom');
console.log(JSON.stringify({
  client: typeof inst.get === 'function' && typeof inst.post === 'function',
  baseURL: inst.defaults.baseURL,
  timeout: inst.defaults.timeout,
  contentType: headers.get('Content-Type'),
  xy: headers.get('X-Y'),
  isErr: isAxiosError(err),
  isCancelFalse: isCancel(err) === false,
  errMsg: err.message,
}));`,
  },
  {
    name: 'toolkit',
    pkg: '@reduxjs/toolkit react redux',
    entry: `import { configureStore, createSlice } from '@reduxjs/toolkit';\nconst slice = createSlice({ name: 'test', initialState: 0, reducers: { inc: s => s + 1 } });\nconsole.log(slice.name, typeof slice.reducer);`,
    deepEntry: `import { configureStore, createSlice, createAction, createReducer, createSelector, combineReducers } from '@reduxjs/toolkit';
const counter = createSlice({
  name: 'counter',
  initialState: { v: 0, log: [] as number[] },
  reducers: {
    inc: (s) => { s.v++; s.log.push(s.v); },
    add: (s, a: { type: string; payload: number }) => { s.v += a.payload; s.log.push(s.v); },
  },
});
const ext = createAction<string>('ext');
const reducer2 = createReducer({ msg: '' }, (b) => {
  b.addCase(ext, (s, a) => { s.msg = a.payload; });
});
const root = combineReducers({ c: counter.reducer, r2: reducer2 });
const store = configureStore({ reducer: root });
store.dispatch(counter.actions.inc());
store.dispatch(counter.actions.add(5));
store.dispatch(ext('hi'));
const selectV = createSelector((s: ReturnType<typeof root>) => s.c.v, (v: number) => v * 2);
console.log(JSON.stringify({
  counter: store.getState().c,
  msg: store.getState().r2.msg,
  selected: selectV(store.getState()),
}));`,
  },
  {
    name: 'rxjs',
    pkg: 'rxjs',
    entry: `import { of, map, filter, toArray } from 'rxjs';\nof(1,2,3,4,5).pipe(filter(x=>x%2===0), map(x=>x*10), toArray()).subscribe(arr=>console.log(JSON.stringify(arr)));`,
    deepEntry: `import { of, from, map, filter, scan, take, mergeMap, catchError, throwError, lastValueFrom, toArray, distinct } from 'rxjs';
(async () => {
  const a = await lastValueFrom(of(1, 2, 3, 4, 5).pipe(
    filter((x) => x % 2 === 1),
    map((x) => x * 10),
    scan((acc, n) => acc + n, 0),
    take(3),
  ));
  const b = await lastValueFrom(from([10, 20, 30]).pipe(
    mergeMap((n) => of(n + 1)),
    toArray(),
  ));
  const c = await lastValueFrom(throwError(() => new Error('boom')).pipe(
    catchError(() => of('caught')),
  ));
  const d = await lastValueFrom(of(1, 1, 2, 3, 3, 4).pipe(distinct(), toArray()));
  console.log(JSON.stringify({ a, b, c, d }));
})();`,
  },
  {
    name: 'immer',
    pkg: 'immer',
    entry: `import { produce } from 'immer';\nconst o = { a: 1, b: [1,2] };\nconst n = produce(o, d => { d.a = 2; d.b.push(3); });\nconsole.log(o.a, n.a, o === n);`,
    deepEntry: `import { produce, produceWithPatches, applyPatches, isDraft, enablePatches } from 'immer';
enablePatches();
const base = { a: 1, list: [1, 2, 3], nested: { x: 10 } };
const next = produce(base, (d) => { d.a = 2; d.list.push(4); d.nested.x = 99; });
const [withPatches, patches] = produceWithPatches(base, (d) => { d.a = 100; });
const applied = applyPatches(base, patches);
let drafted = false;
produce(base, (d) => { drafted = isDraft(d); });
console.log(JSON.stringify({
  baseA: base.a,
  nextA: next.a,
  shareList: base.list === next.list,
  shareNested: base.nested === next.nested,
  newListLen: next.list.length,
  withPatches: withPatches.a,
  appliedA: applied.a,
  drafted,
}));`,
  },
  {
    name: 'superjson',
    pkg: 'superjson',
    entry: `import superjson from 'superjson';\nconst d = { s: new Set([1,2]), m: new Map([['a',1]]) };\nconst r = superjson.parse(superjson.stringify(d)) as typeof d;\nconsole.log(r.s instanceof Set, r.m instanceof Map);`,
  },
  {
    name: 'express',
    pkg: 'express',
    entry: `import express from 'express';\nconst app = express();\napp.get('/t', (q,s)=>s.json({ok:true}));\nconsole.log(typeof app.listen, typeof app.get);`,
    deepEntry: `import express, { Router } from 'express';
const app = express();
const router = Router();
app.use((_req: any, _res: any, next: any) => next());
app.get('/users/:id', (req: any, res: any) => res.json({ id: req.params.id }));
router.get('/inner', (_req: any, res: any) => res.send('inner'));
app.use('/api', router);
console.log(JSON.stringify({
  hasListen: typeof app.listen === 'function',
  hasGet: typeof app.get === 'function',
  hasUse: typeof app.use === 'function',
  routerOk: typeof Router === 'function',
  json: typeof express.json === 'function',
  urlEnc: typeof express.urlencoded === 'function',
  staticFn: typeof express.static === 'function',
  routerInst: typeof router.get === 'function',
}));`,
  },
  {
    name: 'react',
    pkg: 'react',
    entry: `import React from 'react';\nconst el = React.createElement('div', {id:'t'}, 'hi');\nconsole.log(el.type, el.props.id);`,
    deepEntry: `import React, { createElement, Children, Fragment, Component, isValidElement, cloneElement, version } from 'react';
const el = createElement('div', { id: 't' }, createElement('span', null, 'a'), createElement('span', null, 'b'));
const cloned = cloneElement(el, { 'data-x': '1' });
const arr = Children.toArray(el.props.children);
console.log(JSON.stringify({
  type: el.type,
  id: el.props.id,
  kids: arr.length,
  cloned: cloned.props['data-x'],
  fragment: typeof Fragment === 'symbol' || typeof Fragment === 'object',
  comp: typeof Component === 'function',
  isElem: isValidElement(el),
  v: typeof version === 'string' && version.length > 0,
  reactDef: typeof React === 'object',
}));`,
  },
  {
    name: 'commander',
    pkg: 'commander',
    entry: `import { Command } from 'commander';\nconst p = new Command();\np.option('-n, --name <str>', 'name').parse(['node', 'test', '--name', 'hello']);\nconsole.log(p.opts().name);`,
    deepEntry: `import { Command, Option, Argument } from 'commander';
const p = new Command();
p.name('test').version('1.2.3').description('A test program');
p.addOption(new Option('-n, --name <str>', 'name').default('anon'));
p.addOption(new Option('--mode <m>', 'mode').choices(['a', 'b']).default('a'));
p.addArgument(new Argument('<file>', 'input file'));
p.parse(['node', 'test', '--name', 'alice', '--mode', 'b', 'in.txt'], { from: 'node' });
console.log(JSON.stringify({
  name: p.opts().name,
  mode: p.opts().mode,
  arg: p.args[0],
  ver: p.version(),
  desc: p.description(),
}));`,
  },
  {
    name: 'eventemitter3',
    pkg: 'eventemitter3',
    entry: `import EE from 'eventemitter3';\nconst e = new EE();\nlet v = 0;\ne.on('x', (n: number) => v = n);\ne.emit('x', 42);\nconsole.log(v);`,
  },
  {
    name: 'ms',
    pkg: 'ms',
    entry: `import ms from 'ms';\nconsole.log(ms('2 days'), ms(60000));`,
  },
  {
    name: 'dotenv',
    pkg: 'dotenv',
    entry: `import dotenv from 'dotenv';\nconsole.log(typeof dotenv.config, typeof dotenv.parse);`,
  },
  {
    name: 'jsonwebtoken',
    pkg: 'jsonwebtoken',
    entry: `import jwt from 'jsonwebtoken';\nconst t = jwt.sign({uid:1},'secret');\nconst d = jwt.verify(t,'secret') as any;\nconsole.log(d.uid);`,
  },
  {
    name: 'bcryptjs',
    pkg: 'bcryptjs',
    entry: `import bcrypt from 'bcryptjs';\nconst h = bcrypt.hashSync('pw', 4);\nconsole.log(bcrypt.compareSync('pw', h));`,
  },
  {
    name: 'clsx',
    pkg: 'clsx',
    entry: `import { clsx } from 'clsx';\nconsole.log(clsx('a', false, 'b', {c:true, d:false}, ['e']));`,
  },
  {
    name: 'tiny-invariant',
    pkg: 'tiny-invariant',
    entry: `import invariant from 'tiny-invariant';\ninvariant(true, 'ok');\nconsole.log('pass');`,
  },
  {
    name: 'tanstack-query',
    pkg: '@tanstack/query-core',
    entry: `import { QueryClient } from '@tanstack/query-core';\nconst qc = new QueryClient();\nqc.fetchQuery({queryKey:['t'],queryFn:()=>Promise.resolve(42)}).then(r=>{console.log(r);qc.clear();});`,
    deepEntry: `import { QueryClient } from '@tanstack/query-core';
(async () => {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const a = await qc.fetchQuery({ queryKey: ['a'], queryFn: () => Promise.resolve(42) });
  const b = await qc.fetchQuery({ queryKey: ['b', 1], queryFn: () => Promise.resolve('hi') });
  await qc.invalidateQueries({ queryKey: ['a'] });
  const cache = qc.getQueryCache();
  const all = cache.getAll().length;
  qc.clear();
  const cleared = qc.getQueryCache().getAll().length;
  console.log(JSON.stringify({ a, b, all, cleared }));
})();`,
  },
  {
    name: 'fast-glob',
    pkg: 'fast-glob',
    entry: `import fg from 'fast-glob';\nconsole.log(typeof fg, typeof fg.sync);`,
  },
  {
    name: 'micromatch',
    pkg: 'micromatch',
    entry: `import mm from 'micromatch';\nconsole.log(mm(['foo.js','bar.ts','baz.js'], '*.js'));`,
  },
  {
    name: 'semver',
    pkg: 'semver',
    entry: `import semver from 'semver';\nconsole.log(semver.gt('2.0.0','1.0.0'), semver.valid('1.2.3'));`,
  },
  {
    name: 'debug',
    pkg: 'debug',
    entry: `import debug from 'debug';\nconst log = debug('test');\nconsole.log(typeof log);`,
  },
  {
    name: 'chalk',
    pkg: 'chalk@5',
    entry: `import chalk from 'chalk';\nconsole.log(chalk.red('hello'));`,
    deepEntry: `import chalk, { supportsColor, Chalk } from 'chalk';
const red = chalk.red('hello');
const blueBold = chalk.blue.bold('world');
const tpl = chalk.green('x ' + 'y' + ' z');
const hex = chalk.hex('#ff8800')('orange');
const bg = chalk.bgYellow.black('warn');
const custom = new Chalk({ level: 0 });
const plain = custom.red('plain');
console.log(JSON.stringify({
  red,
  blueBold,
  tpl,
  hex,
  bg,
  hasSupport: typeof supportsColor === 'object' || supportsColor === false,
  level: typeof chalk.level === 'number',
  plainNoAnsi: plain === 'plain',
}));`,
  },
  {
    name: 'yaml',
    pkg: 'yaml',
    entry: `import { parse } from 'yaml';\nconsole.log(JSON.stringify(parse('a: 1\\nb: 2')));`,
    deepEntry: `import { parse, stringify, parseDocument } from 'yaml';
const obj = parse('a: 1\\nb:\\n  - 1\\n  - 2\\nc:\\n  d: hello\\n');
const out = stringify({ x: 1, y: [10, 20], z: { p: 'q' } });
const doc = parseDocument('foo: bar\\nlist: [1, 2, 3]\\n');
const docOut = doc.toJS();
console.log(JSON.stringify({
  obj,
  outHasX: out.includes('x: 1'),
  outHasY: out.includes('- 10') || out.includes('- 10\\n'),
  doc: docOut,
}));`,
  },
  {
    name: 'yargs',
    pkg: 'yargs',
    entry: `import yargs from 'yargs';\nconsole.log(typeof yargs);`,
    format: 'cjs',
    deepEntry: `import yargs from 'yargs';
import { hideBin } from 'yargs/helpers';
const argv = yargs(['--name', 'alice', '--age', '30', '--flag', 'pos1'])
  .option('name', { type: 'string' })
  .option('age', { type: 'number' })
  .option('flag', { type: 'boolean' })
  .parseSync();
console.log(JSON.stringify({
  name: argv.name,
  age: argv.age,
  flag: argv.flag,
  pos: argv._,
  hideBin: typeof hideBin === 'function',
}));`,
  },
  {
    name: 'effect',
    pkg: 'effect',
    entry: `import { Effect, pipe } from 'effect';\nconst p = pipe(Effect.succeed(42), Effect.map((n: number) => n + 1));\nEffect.runPromise(p).then(r => console.log(r));`,
    deepEntry: `import { Effect, pipe } from 'effect';
const program = pipe(
  Effect.succeed(10),
  Effect.map((n: number) => n * 2),
  Effect.flatMap((n: number) => Effect.succeed(n + 5)),
  Effect.tap((n: number) => Effect.sync(() => { void n; })),
);
const sum = pipe(
  Effect.succeed([1, 2, 3, 4, 5]),
  Effect.map((arr: number[]) => arr.reduce((a, b) => a + b, 0)),
);
const fail = pipe(
  Effect.fail('boom' as const),
  Effect.catchAll(() => Effect.succeed('recovered' as const)),
);
Promise.all([
  Effect.runPromise(program),
  Effect.runPromise(sum),
  Effect.runPromise(fail),
]).then(([a, b, c]) => {
  console.log(JSON.stringify({ a, b, c }));
});`,
  },
  {
    name: 'vue',
    pkg: 'vue',
    entry: `import { ref, computed } from 'vue';\nconst c = ref(0);\nconst d = computed(() => c.value * 2);\nconsole.log(c.value, d.value);`,
    deepEntry: `import { ref, computed, reactive, isRef, isReactive, toRefs, readonly, shallowRef, customRef } from 'vue';
const c = ref(0);
const dbl = computed(() => c.value * 2);
const obj = reactive({ a: 1, b: 2 });
const ro = readonly(obj);
const sr = shallowRef({ deep: 1 });
c.value = 5;
obj.a = 10;
const refs = toRefs(obj);
console.log(JSON.stringify({
  ref: c.value,
  dbl: dbl.value,
  isRef: isRef(c),
  reactiveOk: isReactive(obj),
  readonlyOk: isReactive(ro),
  refsA: refs.a.value,
  shallowOk: isRef(sr),
  customRefOk: typeof customRef === 'function',
}));`,
  },
  {
    name: 'svelte',
    pkg: 'svelte',
    entry: `import { readable } from 'svelte/store';\nconst t = readable(0, set => { set(42); return () => {}; });\nlet v; t.subscribe(x => v = x);\nconsole.log(v);`,
    deepEntry: `import { readable, writable, derived, get } from 'svelte/store';
const r = readable(0, (set: (v: number) => void) => { set(42); return () => {}; });
const w = writable(10);
const d = derived(w, ($w: number) => $w * 3);
let rv = -1;
let dv = -1;
r.subscribe((x: number) => { rv = x; });
const unsubD = d.subscribe((x: number) => { dv = x; });
w.set(100);
const wv = get(w);
w.update((v: number) => v + 5);
unsubD();
console.log(JSON.stringify({
  readable: rv,
  writable: wv,
  updated: get(w),
  derived: dv,
}));`,
  },
  // svelte tree-shaking 스펙트럼. `platform: "browser"`가 필수 — svelte의
  // package.json `exports` 조건부 resolve가 node에서는 서버 stub
  // (`index-server.js`, mount가 throw stub만)을 내주고, browser에서만 풀 client
  // runtime(`index-client.js`)을 내주기 때문이다. node 기본으로 돌리면 #1567/#1626
  // 회귀 지표가 전혀 드러나지 않는다. 엔트리는 DOM을 건드리지 않아 node로도 실행 가능.
  {
    // core 5개 API — reactivity + effect + props 서브시스템 대부분 reachable.
    name: 'svelte-mount',
    pkg: 'svelte',
    platform: 'browser',
    entry: `import { mount, unmount, untrack, tick, flushSync } from 'svelte';\nconsole.log([mount, unmount, untrack, tick, flushSync].map(f => typeof f).join(','));`,
  },
  {
    // minified 쌍 — tree-shaking이 아니라 minifier 품질 비교용.
    // unminified와 달리 ZNTC가 esbuild보다 커지는 갭이 이 시나리오에서 드러난다.
    name: 'svelte-mount-min',
    pkg: 'svelte',
    platform: 'browser',
    minify: true,
    entry: `import { mount, unmount, untrack, tick, flushSync } from 'svelte';\nconsole.log([mount, unmount, untrack, tick, flushSync].map(f => typeof f).join(','));`,
  },
  {
    // 광범위 surface — lifecycle + context + store까지 끌어옴.
    name: 'svelte-full',
    pkg: 'svelte',
    platform: 'browser',
    entry: `import { mount, unmount, untrack, tick, flushSync, onMount, onDestroy, getContext, setContext, hasContext } from 'svelte';\nimport { readable, writable, derived } from 'svelte/store';\nconsole.log([mount, unmount, untrack, tick, flushSync, onMount, onDestroy, getContext, setContext, hasContext, readable, writable, derived].map(f => typeof f).join(','));`,
  },
  {
    name: 'svelte-full-min',
    pkg: 'svelte',
    platform: 'browser',
    minify: true,
    entry: `import { mount, unmount, untrack, tick, flushSync, onMount, onDestroy, getContext, setContext, hasContext } from 'svelte';\nimport { readable, writable, derived } from 'svelte/store';\nconsole.log([mount, unmount, untrack, tick, flushSync, onMount, onDestroy, getContext, setContext, hasContext, readable, writable, derived].map(f => typeof f).join(','));`,
  },
  {
    name: 'solid-js',
    pkg: 'solid-js',
    entry: `import { createSignal } from 'solid-js';\nconst [count, setCount] = createSignal(0);\nsetCount(1);\nconsole.log(count());`,
    deepEntry: `import { createSignal, createMemo, createEffect, createRoot, batch, untrack } from 'solid-js';
let result: any;
createRoot((dispose) => {
  const [c, setC] = createSignal(0);
  const dbl = createMemo(() => c() * 2);
  let eff = -1;
  createEffect(() => { eff = c() + 1; });
  setC(5);
  batch(() => { setC(10); setC(11); });
  const unt = untrack(() => c());
  result = { c: c(), dbl: dbl(), eff, unt };
  dispose();
});
console.log(JSON.stringify(result));`,
  },
  {
    name: 'three',
    pkg: 'three',
    entry: `import { Vector3 } from 'three';\nconst v = new Vector3(1, 2, 3);\nconsole.log(v.length().toFixed(2));`,
    deepEntry: `import { Vector3, Matrix4, Quaternion, Box3, Euler, Color, MathUtils, Plane } from 'three';
const v = new Vector3(1, 2, 3);
const w = new Vector3(4, 5, 6);
const dot = v.dot(w);
const cross = v.clone().cross(w);
const m = new Matrix4().makeRotationY(Math.PI / 2);
const q = new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0), Math.PI);
const e = new Euler(0, Math.PI / 4, 0);
const c = new Color(0.5, 0.25, 1.0);
const box = new Box3().setFromCenterAndSize(v.clone(), new Vector3(2, 2, 2));
console.log(JSON.stringify({
  len: +v.length().toFixed(4),
  dot,
  cross: [cross.x, cross.y, cross.z],
  mDet: +m.determinant().toFixed(4),
  qNorm: +q.length().toFixed(4),
  eulerY: +e.y.toFixed(4),
  hex: c.getHex(),
  boxMin: [box.min.x, box.min.y, box.min.z],
  clamp: MathUtils.clamp(15, 0, 10),
  hasPlane: typeof Plane === 'function',
}));`,
  },
  {
    name: 'graphql',
    pkg: 'graphql',
    entry: `import { parse } from 'graphql';\nconst d = parse('{ hello }');\nconsole.log(d.definitions[0].selectionSet.selections[0].name.value);`,
    deepEntry: `import { parse, print, validate, buildSchema, Kind, visit, GraphQLString, GraphQLInt, GraphQLObjectType, GraphQLSchema, graphqlSync } from 'graphql';
const doc = parse('query GetUser($id: ID!) { user(id: $id) { id name posts(limit: 5) { title } } }');
const fieldNames: string[] = [];
visit(doc, {
  Field(node) { fieldNames.push(node.name.value); },
});
const printed = print(doc).replace(/\\s+/g, ' ').trim();
const schema = buildSchema('type Query { hello(name: String!): String }');
const validQuery = parse('{ hello(name: \"world\") }');
const errs = validate(schema, validQuery);
const QueryType = new GraphQLObjectType({
  name: 'Query',
  fields: {
    add: {
      type: GraphQLInt,
      args: { a: { type: GraphQLInt }, b: { type: GraphQLInt } },
      resolve: (_: unknown, { a, b }: { a: number; b: number }) => a + b,
    },
    greet: {
      type: GraphQLString,
      args: { name: { type: GraphQLString } },
      resolve: (_: unknown, { name }: { name: string }) => 'hi ' + name,
    },
  },
});
const execSchema = new GraphQLSchema({ query: QueryType });
const execResult = graphqlSync({ schema: execSchema, source: '{ add(a: 2, b: 3) greet(name: \"zntc\") }' });
console.log(JSON.stringify({
  defKind: doc.definitions[0].kind,
  isOpDef: doc.definitions[0].kind === Kind.OPERATION_DEFINITION,
  fields: fieldNames,
  printedHasUser: printed.includes('user(id: $id)'),
  validateOk: errs.length === 0,
  execData: execResult.data,
  execErrs: execResult.errors?.length ?? 0,
}));`,
  },
  {
    name: 'supabase',
    pkg: '@supabase/supabase-js',
    entry: `import { createClient } from '@supabase/supabase-js';\nconsole.log(typeof createClient);`,
    deepEntry: `import { createClient, type SupabaseClient } from '@supabase/supabase-js';
let lastUrl = '';
let lastMethod = '';
const fakeFetch: typeof fetch = async (input, init) => {
  lastUrl = typeof input === 'string' ? input : (input as URL).toString();
  lastMethod = init?.method ?? 'GET';
  return new Response(JSON.stringify([{ id: 1, name: 'a' }]), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
};
const c: SupabaseClient = createClient('https://x.supabase.co', 'anon-key', {
  global: { fetch: fakeFetch },
  auth: { persistSession: false, autoRefreshToken: false },
});
(async () => {
  const { data, error } = await c.from('users').select('id,name').eq('active', true).order('id', { ascending: false }).limit(10);
  console.log(JSON.stringify({
    queryUrl: lastUrl.includes('/rest/v1/users') && lastUrl.includes('select=id%2Cname'),
    queryMethod: lastMethod,
    rowsLen: Array.isArray(data) ? data.length : -1,
    err: error,
    auth: {
      signIn: typeof c.auth.signInWithPassword,
      signOut: typeof c.auth.signOut,
      getSession: typeof c.auth.getSession,
      onAuthStateChange: typeof c.auth.onAuthStateChange,
    },
    surface: {
      storage: typeof c.storage.from,
      channel: typeof c.channel,
      rpc: typeof c.rpc,
      removeAllChannels: typeof c.removeAllChannels,
    },
  }));
})();`,
  },
  {
    name: 'mobx',
    pkg: 'mobx',
    entry: `import { observable } from 'mobx';\nconst o = observable({ v: 0 });\no.v = 42;\nconsole.log(o.v);`,
    deepEntry: `import { observable, autorun, makeAutoObservable, runInAction, isObservable, action, computed } from 'mobx';
class Store {
  v = 0;
  list: number[] = [];
  constructor() { makeAutoObservable(this); }
  inc() { this.v++; this.list.push(this.v); }
  get dbl() { return this.v * 2; }
}
const s = new Store();
let runs = 0;
const dispose = autorun(() => { runs++; void s.v; });
s.inc();
s.inc();
runInAction(() => { s.v = 100; s.list.push(99); });
const obs = observable.box(7);
obs.set(8);
dispose();
console.log(JSON.stringify({
  v: s.v,
  dbl: s.dbl,
  list: s.list,
  runs,
  obsBox: obs.get(),
  isObs: isObservable(s),
  hasAction: typeof action === 'function',
  hasComputed: typeof computed === 'function',
}));`,
  },
  {
    name: 'jotai',
    pkg: 'jotai react',
    entry: `import { atom, createStore } from 'jotai';\nconst a = atom(0);\nconst s = createStore();\ns.set(a, 42);\nconsole.log(s.get(a));`,
    external: ['react'],
    deepEntry: `import { atom, createStore } from 'jotai';
const a = atom(0);
const dbl = atom((get) => get(a) * 2);
const writer = atom(null, (get, set, n: number) => { set(a, get(a) + n); });
const s = createStore();
const watched: number[] = [];
const unsub = s.sub(a, () => { watched.push(s.get(a)); });
s.set(a, 10);
s.set(writer, 5);
unsub();
console.log(JSON.stringify({
  a: s.get(a),
  dbl: s.get(dbl),
  watched,
}));`,
  },
  {
    name: 'mitt',
    pkg: 'mitt',
    entry: `import mitt from 'mitt';\nconst e = mitt();\nlet v = 0;\ne.on('x', (n) => v = n);\ne.emit('x', 42);\nconsole.log(v);`,
  },
  {
    name: 'zustand',
    pkg: 'zustand',
    entry: `import { createStore } from 'zustand/vanilla';\nconst store = createStore((set) => ({ count: 0, inc: () => set((s) => ({ count: s.count + 1 })) }));\nstore.getState().inc();\nconsole.log(store.getState().count);`,
    deepEntry: `import { createStore } from 'zustand/vanilla';
type S = { count: number; log: number[]; inc: () => void; add: (n: number) => void };
const store = createStore<S>((set) => ({
  count: 0,
  log: [],
  inc: () => set((s) => ({ count: s.count + 1, log: [...s.log, s.count + 1] })),
  add: (n) => set((s) => ({ count: s.count + n, log: [...s.log, s.count + n] })),
}));
const snaps: number[] = [];
const unsub = store.subscribe((s) => { snaps.push(s.count); });
store.getState().inc();
store.getState().inc();
store.getState().add(10);
unsub();
store.getState().add(5);
console.log(JSON.stringify({
  count: store.getState().count,
  log: store.getState().log,
  snaps,
}));`,
  },
  {
    name: 'valtio',
    pkg: 'valtio',
    entry: `import { proxy, snapshot } from 'valtio/vanilla';\nconst state = proxy({ count: 0 });\nstate.count = 42;\nconsole.log(snapshot(state).count);`,
    deepEntry: `import { proxy, snapshot, subscribe, ref } from 'valtio/vanilla';
(async () => {
  const state = proxy({ count: 0, list: [] as number[], nested: { x: 1 } });
  let notifyCount = 0;
  const unsub = subscribe(state, () => { notifyCount++; });
  state.count = 1;
  state.count = 2;
  state.list.push(10, 20);
  state.nested.x = 99;
  await new Promise((r) => setTimeout(r, 30));
  const snap = snapshot(state);
  unsub();
  state.count = 999;
  console.log(JSON.stringify({
    count: snap.count,
    list: [...snap.list],
    nestedX: snap.nested.x,
    notified: notifyCount > 0,
    liveAfterUnsub: state.count === 999,
    hasRef: typeof ref === 'function',
  }));
})();`,
  },
  {
    name: 'react-dom',
    pkg: 'react-dom react',
    entry: `import { renderToString } from 'react-dom/server';\nimport { createElement } from 'react';\nconsole.log(renderToString(createElement('div', null, 'Hello')));`,
    deepEntry: `import { renderToString, renderToStaticMarkup, version } from 'react-dom/server';
import { createElement, Fragment } from 'react';
const tree = createElement('div', { id: 'a' },
  createElement('h1', null, 'Title'),
  createElement('ul', null,
    createElement('li', { key: 1 }, 'one'),
    createElement('li', { key: 2 }, 'two'),
  ),
  createElement(Fragment, null, createElement('span', null, 'frag')),
);
const html1 = renderToString(tree);
const html2 = renderToStaticMarkup(createElement('p', { className: 'x' }, 'static'));
console.log(JSON.stringify({
  ssrHasTitle: html1.includes('<h1>Title</h1>'),
  ssrHasList: html1.includes('<ul>') && html1.includes('one') && html1.includes('two'),
  ssrFrag: html1.includes('frag'),
  staticP: html2 === '<p class="x">static</p>',
  v: typeof version === 'string',
}));`,
  },
  {
    name: 'd3',
    pkg: 'd3',
    entry: `import { scaleLinear, range } from 'd3';\nconst s = scaleLinear().domain([0, 100]).range([0, 1]);\nconsole.log(s(50));`,
    deepEntry: `import { scaleLinear, scaleLog, range, extent, mean, median, max, min, bisector, ascending } from 'd3';
const data = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5];
const s = scaleLinear().domain([0, 100]).range([0, 1]);
const sl = scaleLog().domain([1, 1000]).range([0, 1]);
const r = range(0, 5);
const ext = extent(data);
const m = mean(data);
const med = median(data);
const mx = max(data);
const mn = min(data);
const bis = bisector((d: number) => d).left;
const sorted = data.slice().sort(ascending);
const idx = bis(sorted, 4);
console.log(JSON.stringify({
  s50: +s(50).toFixed(4),
  sl100: +sl(100).toFixed(4),
  range: r,
  ext,
  mean: m,
  median: med,
  max: mx,
  min: mn,
  bisIdx: idx,
}));`,
  },
  {
    name: 'hono',
    pkg: 'hono',
    entry: `import { Hono } from 'hono';\nconst app = new Hono();\napp.get('/', (c) => c.text('Hello'));\nconsole.log('routes:', app.routes.length);`,
    deepEntry: `import { Hono } from 'hono';
(async () => {
  const app = new Hono();
  app.get('/', (c) => c.text('Hello'));
  app.get('/u/:id', (c) => c.json({ id: c.req.param('id') }));
  app.post('/p', async (c) => c.json(await c.req.json()));
  const r1 = await app.request('/');
  const t1 = await r1.text();
  const r2 = await app.request('/u/42');
  const j2 = await r2.json();
  const r3 = await app.request('/p', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ k: 'v' }),
  });
  const j3 = await r3.json();
  console.log(JSON.stringify({
    t1,
    j2,
    j3,
    routeCount: app.routes.length,
  }));
})();`,
  },
  {
    name: 'dayjs',
    pkg: 'dayjs',
    entry: `import dayjs from 'dayjs';\nconsole.log(dayjs('2024-01-01').format('YYYY/MM/DD'));`,
    deepEntry: `import dayjs from 'dayjs';
const d = dayjs('2024-06-15T12:00:00.000Z');
const next = d.add(10, 'day');
const before = d.subtract(2, 'month');
const diff = next.diff(before, 'day');
console.log(JSON.stringify({
  iso: d.toISOString(),
  next: next.format('YYYY-MM-DD'),
  before: before.format('YYYY-MM-DD'),
  diff,
  year: d.year(),
  month: d.month() + 1,
  day: d.date(),
  format: d.format('DD/MM/YYYY HH:mm'),
}));`,
  },
  {
    name: 'nanoid',
    pkg: 'nanoid',
    entry: `import { nanoid } from 'nanoid';\nconsole.log(nanoid().length >= 21);`,
  },
  {
    name: 'zlib',
    pkg: 'pako',
    entry: `import pako from 'pako';\nconst d = pako.deflate('hello world');\nconsole.log(pako.inflate(d, { to: 'string' }));`,
  },
  {
    name: 'fp-ts',
    pkg: 'fp-ts',
    entry: `import { pipe } from 'fp-ts/function';\nimport { some, map, getOrElse } from 'fp-ts/Option';\nconst r = pipe(some(1), map((n: number) => n + 1), getOrElse(() => 0));\nconsole.log(r);`,
  },
  {
    name: 'neverthrow',
    pkg: 'neverthrow',
    entry: `import { ok, err } from 'neverthrow';\nconst r = ok(42).map((n: number) => n + 1);\nconsole.log(r.isOk(), r.isOk() ? r.value : null);`,
  },
  {
    name: 'drizzle-orm',
    pkg: 'drizzle-orm',
    entry: `import { sql } from 'drizzle-orm';\nconsole.log(typeof sql);`,
  },
  // --- 추가 패키지 ---
  {
    name: 'tslib',
    pkg: 'tslib',
    entry: `import { __awaiter } from 'tslib';\nconsole.log(typeof __awaiter);`,
  },
  {
    name: 'iconv-lite',
    pkg: 'iconv-lite',
    entry: `import iconv from 'iconv-lite';\nconsole.log(typeof iconv.encode);`,
  },
  {
    name: 'qs',
    pkg: 'qs',
    entry: `import qs from 'qs';\nconsole.log(qs.stringify({ a: 1, b: 2 }));`,
  },
  {
    name: 'change-case',
    pkg: 'change-case',
    entry: `import { camelCase } from 'change-case';\nconsole.log(camelCase('hello-world'));`,
  },
  {
    name: 'path-to-regexp',
    pkg: 'path-to-regexp',
    entry: `import { match } from 'path-to-regexp';\nconst fn = match('/user/:id');\nconsole.log(typeof fn);`,
  },
  {
    name: 'mime-types',
    pkg: 'mime-types',
    entry: `import mime from 'mime-types';\nconsole.log(mime.lookup('test.js'));`,
  },
  {
    name: 'ajv',
    pkg: 'ajv',
    entry: `import Ajv from 'ajv';\nconst ajv = new Ajv();\nconst v = ajv.compile({type:'number'});\nconsole.log(v(42));`,
  },
  {
    name: 'cac',
    pkg: 'cac',
    entry: `import cac from 'cac';\nconst cli = cac('test');\nconsole.log(typeof cli.parse);`,
  },
  {
    name: 'defu',
    pkg: 'defu',
    entry: `import { defu } from 'defu';\nconsole.log(JSON.stringify(defu({ a: 1 }, { a: 2, b: 3 })));`,
  },
  {
    name: 'pathe',
    pkg: 'pathe',
    entry: `import { join } from 'pathe';\nconsole.log(join('a', 'b', 'c'));`,
  },
  {
    name: 'destr',
    pkg: 'destr',
    entry: `import { destr } from 'destr';\nconsole.log(destr('{"a":1}').a);`,
  },
  {
    name: 'hookable',
    pkg: 'hookable',
    entry: `import { createHooks } from 'hookable';\nconst hooks = createHooks();\nconsole.log(typeof hooks.hook);`,
  },
  {
    name: 'minimatch',
    pkg: 'minimatch',
    entry: `import { minimatch } from 'minimatch';\nconsole.log(minimatch('foo.js', '*.js'));`,
  },
  {
    name: 'cheerio',
    pkg: 'cheerio',
    entry: `import { load } from 'cheerio';\nconst doc = load('<h1>Hello</h1>');\nconsole.log(doc('h1').text());`,
  },
  // --- 추가 패키지 (소형 유틸리티) ---
  {
    name: 'is-glob',
    pkg: 'is-glob',
    entry: `import isGlob from 'is-glob';\nconsole.log(isGlob('*.js'));`,
  },
  {
    name: 'glob-parent',
    pkg: 'glob-parent',
    entry: `import gp from 'glob-parent';\nconsole.log(gp('a/b/*.js'));`,
  },
  {
    name: 'escape-string-regexp',
    pkg: 'escape-string-regexp',
    entry: `import esc from 'escape-string-regexp';\nconsole.log(esc('a.b'));`,
  },
  {
    name: 'fast-deep-equal',
    pkg: 'fast-deep-equal',
    entry: `import eq from 'fast-deep-equal';\nconsole.log(eq({ a: 1 }, { a: 1 }));`,
  },
  {
    name: 'deepmerge',
    pkg: 'deepmerge',
    entry: `import dm from 'deepmerge';\nconsole.log(JSON.stringify(dm({ a: 1 }, { b: 2 })));`,
  },
  {
    name: 'color-convert',
    pkg: 'color-convert',
    entry: `import c from 'color-convert';\nconsole.log(c.rgb.hex(255, 0, 0));`,
  },
  {
    name: 'picomatch',
    pkg: 'picomatch',
    entry: `import pm from 'picomatch';\nconsole.log(pm.isMatch('foo.js', '*.js'));`,
  },
  {
    name: 'type-is',
    pkg: 'type-is',
    entry: `import typeis from 'type-is';\nconsole.log(typeof typeis);`,
  },
  {
    name: 'object-assign',
    pkg: 'object-assign',
    entry: `import oa from 'object-assign';\nconsole.log(typeof oa);`,
  },
  {
    name: 'has-flag',
    pkg: 'has-flag',
    entry: `import hf from 'has-flag';\nconsole.log(typeof hf);`,
  },
  {
    name: 'p-limit',
    pkg: 'p-limit',
    entry: `import pLimit from 'p-limit';\nconst l = pLimit(1);\nconsole.log(typeof l);`,
  },
  {
    name: 'strip-ansi',
    pkg: 'strip-ansi',
    entry: `import strip from 'strip-ansi';\nconsole.log(strip('hello'));`,
  },
  {
    name: 'ansi-regex',
    pkg: 'ansi-regex',
    entry: `import ar from 'ansi-regex';\nconsole.log(typeof ar);`,
  },
  {
    name: 'wrap-ansi',
    pkg: 'wrap-ansi',
    entry: `import wrap from 'wrap-ansi';\nconsole.log(typeof wrap);`,
  },
  {
    name: 'supports-color',
    pkg: 'supports-color',
    entry: `import sc from 'supports-color';\nconsole.log(typeof sc);`,
  },
  {
    name: 'cross-spawn',
    pkg: 'cross-spawn',
    entry: `import cs from 'cross-spawn';\nconsole.log(typeof cs.spawn);`,
  },
  {
    name: 'lru-cache',
    pkg: 'lru-cache',
    entry: `import { LRUCache } from 'lru-cache';\nconst c = new LRUCache({ max: 10 });\nc.set('a', 1);\nconsole.log(c.get('a'));`,
  },
  {
    name: 'signal-exit',
    pkg: 'signal-exit',
    entry: `import { onExit } from 'signal-exit';\nconsole.log(typeof onExit);`,
  },
  {
    name: 'which',
    pkg: 'which',
    entry: `import which from 'which';\nconsole.log(typeof which);`,
  },
  {
    name: 'string-width',
    pkg: 'string-width',
    entry: `import sw from 'string-width';\nconsole.log(sw('hello'));`,
  },
  // --- 추가 패키지 (CJS 유틸리티 + 마이크로 라이브러리) ---
  {
    name: 'safe-buffer',
    pkg: 'safe-buffer',
    entry: `import { Buffer } from 'safe-buffer';\nconsole.log(Buffer.alloc(4).length);`,
  },
  {
    name: 'bytes',
    pkg: 'bytes',
    entry: `import bytes from 'bytes';\nconsole.log(bytes(1024));`,
  },
  {
    name: 'depd',
    pkg: 'depd',
    entry: `import depd from 'depd';\nconsole.log(typeof depd);`,
  },
  {
    name: 'merge-descriptors',
    pkg: 'merge-descriptors',
    entry: `import md from 'merge-descriptors';\nconsole.log(typeof md);`,
  },
  {
    name: 'content-type',
    pkg: 'content-type',
    entry: `import ct from 'content-type';\nconsole.log(ct.parse('text/html').type);`,
  },
  {
    name: 'cookie',
    pkg: 'cookie',
    entry: `import { serialize } from 'cookie';\nconsole.log(serialize('a', 'b'));`,
  },
  {
    name: 'cjs-define-property-member-value',
    pkg: '(synthetic)',
    entry: `import { used } from './_smoke_cjs_define_property_member_value_lib.cjs';\nconsole.log(used());`,
    files: {
      '_smoke_cjs_define_property_member_value_lib.cjs':
        `const liveNs = { value: function used() { return "MATCH"; } };\n` +
        `const deadNs = { value: function unused() { return "UNUSED_SMOKE_DEFINE_MEMBER_VALUE"; } };\n` +
        `Object.defineProperty(exports, "used", { value: liveNs.value });\n` +
        `Object.defineProperty(exports, "unused", { value: deadNs.value });\n`,
    },
  },
  {
    name: 'object-freeze-pure-call',
    pkg: '(synthetic)',
    entry: `import { used } from './_smoke_object_freeze_pure_call_lib.js';\nconsole.log(used);`,
    files: {
      '_smoke_object_freeze_pure_call_lib.js':
        `export const used = "MATCH";\n` +
        `const dead = Object.freeze({ marker: "UNUSED_SMOKE_OBJECT_FREEZE" });\n`,
    },
  },
  {
    name: 'object-assign-pure-call',
    pkg: '(synthetic)',
    entry: `import { used } from './_smoke_object_assign_pure_call_lib.js';\nconsole.log(used);`,
    files: {
      '_smoke_object_assign_pure_call_lib.js':
        `export const used = "MATCH";\n` +
        `const dead = Object.assign({}, { marker: "UNUSED_SMOKE_OBJECT_ASSIGN" });\n`,
    },
  },
  {
    name: 'cjs-esmodule-marker-pruning',
    pkg: '(synthetic)',
    entry: `import { used } from './_smoke_cjs_esmodule_marker_pruning_lib.cjs';\nconsole.log(used());`,
    files: {
      '_smoke_cjs_esmodule_marker_pruning_lib.cjs':
        `Object.defineProperty(exports, "__esModule", { value: true });\n` +
        `function used() { return "MATCH"; }\n` +
        `function dead() { return "UNUSED_SMOKE_CJS_ESMODULE"; }\n` +
        `Object.defineProperty(exports, "used", { value: used });\n` +
        `Object.defineProperty(exports, "dead", { value: dead });\n`,
    },
  },
  {
    name: 'cjs-module-exports-object-member-value',
    pkg: '(synthetic)',
    entry: `import { used } from './_smoke_cjs_module_exports_object_member_value_lib.cjs';\nconsole.log(used());`,
    files: {
      '_smoke_cjs_module_exports_object_member_value_lib.cjs':
        `const liveNs = { value: function used() { return "MATCH"; } };\n` +
        `const deadNs = { value: function dead() { return "UNUSED_SMOKE_OBJECT_MEMBER_VALUE"; } };\n` +
        `module.exports = { used: liveNs.value, dead: deadNs.value };\n`,
    },
  },
  {
    name: 'on-finished',
    pkg: 'on-finished',
    entry: `import onf from 'on-finished';\nconsole.log(typeof onf);`,
  },
  {
    name: 'statuses',
    pkg: 'statuses',
    entry: `import statuses from 'statuses';\nconsole.log(statuses(200));`,
  },
  {
    name: 'etag',
    pkg: 'etag',
    entry: `import etag from 'etag';\nconsole.log(etag('hello').length > 0);`,
  },
  {
    name: 'vary',
    pkg: 'vary',
    entry: `import vary from 'vary';\nconsole.log(typeof vary);`,
  },
  {
    name: 'flat',
    pkg: 'flat',
    entry: `import { flatten } from 'flat';\nconsole.log(JSON.stringify(flatten({ a: { b: 1 } })));`,
  },
  {
    name: 'retry',
    pkg: 'retry',
    entry: `import retry from 'retry';\nconsole.log(typeof retry.createTimeout);`,
  },
  {
    name: 'camelcase',
    pkg: 'camelcase',
    entry: `import cc from 'camelcase';\nconsole.log(cc('foo-bar'));`,
  },
  {
    name: 'decamelize',
    pkg: 'decamelize',
    entry: `import dc from 'decamelize';\nconsole.log(dc('fooBar'));`,
  },
  {
    name: 'memoize-one',
    pkg: 'memoize-one',
    entry: `import mo from 'memoize-one';\nconst fn = mo((a: number) => a * 2);\nconsole.log(fn(5));`,
  },
  {
    name: 'rfdc',
    pkg: 'rfdc',
    entry: `import rfdc from 'rfdc';\nconst clone = rfdc();\nconsole.log(JSON.stringify(clone({ a: 1 })));`,
  },
  {
    name: 'ohash',
    pkg: 'ohash',
    entry: `import { hash } from 'ohash';\nconsole.log(typeof hash({ a: 1 }));`,
  },
  {
    name: 'nanoevents',
    pkg: 'nanoevents',
    entry: `import { createNanoEvents } from 'nanoevents';\nconst e = createNanoEvents();\nconsole.log(typeof e.on);`,
  },
  // zx: CJS 래핑 모듈 내부의 require("async_hooks")가 ESM 번들에서 동작 안 함
  // → createRequire(import.meta.url) 주입 필요 (esbuild 방식)

  // ============================================================
  // TypeScript-heavy 패키지 — TS→JS 트랜스파일 정확도 검증
  // ============================================================
  {
    name: 'typebox',
    pkg: '@sinclair/typebox',
    entry: `import { Type } from '@sinclair/typebox';\nconst T = Type.Object({ name: Type.String(), age: Type.Number() });\nconsole.log(JSON.stringify(T.type));`,
  },
  {
    name: 'ts-pattern',
    pkg: 'ts-pattern',
    entry: `import { match, P } from 'ts-pattern';\nconst r = match({ type: 'ok', value: 42 }).with({ type: 'ok', value: P.number }, (v) => v.value * 2).otherwise(() => 0);\nconsole.log(r);`,
  },
  {
    name: 'valibot',
    pkg: 'valibot',
    entry: `import * as v from 'valibot';\nconst schema = v.object({ name: v.string(), age: v.number() });\nconst r = v.parse(schema, { name: 'Alice', age: 30 });\nconsole.log(r.name, r.age);`,
  },
  {
    name: 'ts-results-es',
    pkg: 'ts-results-es',
    entry: `import { Ok } from 'ts-results-es';\nconst r = new Ok(42).map(n => n + 1);\nconsole.log(r.isOk(), r.value);`,
  },
  {
    name: 'remeda',
    pkg: 'remeda',
    entry: `import { pipe, map, filter } from 'remeda';\nconst r = pipe([1,2,3,4,5], filter((x: number) => x > 1), map((x: number) => x * 2));\nconsole.log(JSON.stringify(r));`,
  },
  {
    name: 'nanostores',
    pkg: 'nanostores',
    entry: `import { atom, computed } from 'nanostores';\nconst count = atom(0);\nconst doubled = computed(count, (v) => v * 2);\ncount.set(5);\nconsole.log(doubled.get());`,
  },
  {
    name: 'ky',
    pkg: 'ky',
    entry: `import ky from 'ky';\nconsole.log(typeof ky.get, typeof ky.post, typeof ky.create);`,
  },
  // typedi: 번들러 decorator 변환 미지원 → Container API만 검증
  {
    name: 'typedi',
    pkg: 'typedi',
    entry: `import { Container, Token } from 'typedi';\nconst MY_TOKEN = new Token('MY_VALUE');\nContainer.set(MY_TOKEN, 42);\nconsole.log(Container.get(MY_TOKEN));`,
  },
  {
    name: 'io-ts',
    pkg: 'io-ts fp-ts',
    entry: `import * as t from 'io-ts';\nconst User = t.type({ name: t.string, age: t.number });\nconst r = User.decode({ name: 'Alice', age: 30 });\nconsole.log(r._tag);`,
  },
  {
    name: 'type-fest',
    pkg: 'type-fest',
    entry: `import type { CamelCase } from 'type-fest';\nconst x = 'hello';\nconsole.log(x);`,
  },
  {
    name: 'arktype',
    pkg: 'arktype',
    entry: `import { type } from 'arktype';\nconst user = type({ name: 'string', age: 'number' });\nconsole.log(typeof user);`,
  },
  {
    name: 'kysely',
    pkg: 'kysely',
    entry: `import { Kysely, DummyDriver, SqliteAdapter, SqliteIntrospector, SqliteQueryCompiler } from 'kysely';\nconst db = new Kysely({ dialect: { createAdapter: () => new SqliteAdapter(), createDriver: () => new DummyDriver(), createIntrospector: (db) => new SqliteIntrospector(db), createQueryCompiler: () => new SqliteQueryCompiler() } });\nconsole.log(typeof db.selectFrom);`,
  },

  // ============================================================
  // 다운레벨링 스모크 테스트 — 각 ES 타겟별 실제 패키지 빌드+실행
  // ============================================================

  // --- target=es5 (ES2015 전체 다운레벨링) ---
  {
    name: 'lodash-es@es5',
    pkg: 'lodash-es',
    entry: `import { uniq, sortBy } from 'lodash-es';\nconsole.log(JSON.stringify(uniq([1,2,2,3])));`,
    target: 'es5',
  },
  {
    name: 'clsx@es5',
    pkg: 'clsx',
    entry: `import { clsx } from 'clsx';\nconsole.log(clsx('a', false, 'b', {c:true}));`,
    target: 'es5',
  },
  {
    name: 'ms@es5',
    pkg: 'ms',
    entry: `import ms from 'ms';\nconsole.log(ms('2 days'));`,
    target: 'es5',
  },
  {
    name: 'deepmerge@es5',
    pkg: 'deepmerge',
    entry: `import dm from 'deepmerge';\nconsole.log(JSON.stringify(dm({a:1},{b:2})));`,
    target: 'es5',
  },
  {
    name: 'fast-deep-equal@es5',
    pkg: 'fast-deep-equal',
    entry: `import eq from 'fast-deep-equal';\nconsole.log(eq({a:1},{a:1}));`,
    target: 'es5',
  },
  {
    name: 'semver@es5',
    pkg: 'semver',
    entry: `import semver from 'semver';\nconsole.log(semver.gt('2.0.0','1.0.0'));`,
    target: 'es5',
  },

  // --- target=es2015 (ES2016 다운레벨링: **) ---
  {
    name: 'lodash-es@es2015',
    pkg: 'lodash-es',
    entry: `import { uniq } from 'lodash-es';\nconsole.log(JSON.stringify(uniq([1,2,2,3])));`,
    target: 'es2015',
  },
  {
    name: 'superjson@es2015',
    pkg: 'superjson',
    entry: `import superjson from 'superjson';\nconsole.log(superjson.stringify({a:1}));`,
    target: 'es2015',
  },

  // --- target=es2017 (ES2018 다운레벨링: object spread) ---
  {
    name: 'flat@es2017',
    pkg: 'flat',
    entry: `import { flatten } from 'flat';\nconsole.log(JSON.stringify(flatten({a:{b:1}})));`,
    target: 'es2017',
  },
  {
    name: 'defu@es2017',
    pkg: 'defu',
    entry: `import { defu } from 'defu';\nconsole.log(JSON.stringify(defu({a:1},{a:2,b:3})));`,
    target: 'es2017',
  },

  // --- target=es2018 (ES2019 다운레벨링: optional catch) ---
  {
    name: 'picomatch@es2018',
    pkg: 'picomatch',
    entry: `import pm from 'picomatch';\nconsole.log(pm.isMatch('foo.js', '*.js'));`,
    target: 'es2018',
  },

  // --- target=es2019 (ES2020 다운레벨링: ??, ?.) ---
  {
    name: 'semver@es2019',
    pkg: 'semver',
    entry: `import semver from 'semver';\nconsole.log(semver.gt('2.0.0','1.0.0'));`,
    target: 'es2019',
  },
  {
    name: 'clsx@es2019',
    pkg: 'clsx',
    entry: `import { clsx } from 'clsx';\nconsole.log(clsx('a', false, 'b'));`,
    target: 'es2019',
  },
  {
    name: 'nanoid@es2019',
    pkg: 'nanoid',
    entry: `import { nanoid } from 'nanoid';\nconsole.log(nanoid().length >= 21);`,
    target: 'es2019',
  },

  // --- target=es2020 (ES2021 다운레벨링: ??=, ||=, &&=) ---
  {
    name: 'dayjs@es2020',
    pkg: 'dayjs',
    entry: `import dayjs from 'dayjs';\nconsole.log(dayjs('2024-01-01').format('YYYY/MM/DD'));`,
    target: 'es2020',
  },
  {
    name: 'ohash@es2020',
    pkg: 'ohash',
    entry: `import { hash } from 'ohash';\nconsole.log(typeof hash({a:1}));`,
    target: 'es2020',
  },

  // --- target=es2021 (ES2022 다운레벨링: static block, class fields) ---
  {
    name: 'lru-cache@es2021',
    pkg: 'lru-cache',
    entry: `import { LRUCache } from 'lru-cache';\nconst c = new LRUCache({max:10});\nc.set('a',1);\nconsole.log(c.get('a'));`,
    target: 'es2021',
  },
  {
    name: 'nanostores@es2021',
    pkg: 'nanostores',
    entry: `import { atom } from 'nanostores';\nconst c = atom(0);\nc.set(42);\nconsole.log(c.get());`,
    target: 'es2021',
  },

  // ============================================================
  // Engine target tests — --target=chrome80,safari14 등
  // ============================================================
  {
    name: 'lodash-es@chrome80',
    pkg: 'lodash-es',
    entry: `import { groupBy, sortBy, uniq } from 'lodash-es';\nconsole.log(groupBy, sortBy, uniq);`,
    target: 'chrome80',
  },
  {
    name: 'clsx@chrome49',
    pkg: 'clsx',
    entry: `import { clsx } from 'clsx';\nconsole.log(clsx('a', false, 'b', {c:true}));`,
    target: 'chrome49',
  },
  {
    name: 'dayjs@safari14',
    pkg: 'dayjs',
    entry: `import dayjs from 'dayjs';\nconsole.log(dayjs().format('YYYY-MM-DD'));`,
    target: 'safari14',
  },
  {
    name: 'nanoid@node16',
    pkg: 'nanoid',
    entry: `import { nanoid } from 'nanoid';\nconsole.log(nanoid());`,
    target: 'node16',
    platform: 'node',
  },
];

// ============================================================
// Run
// ============================================================

console.log('ZNTC Smoke Test — Real Project Bundling\n');

// CLI: --filter=<패턴> 으로 이름 필터링 (예: --filter=@es5, --filter=lodash).
// 콤마 분리로 여러 패턴 OR 매치: --filter=safe-buffer,cookie,path-to-regexp.
const filterArg = process.argv.find((a) => a.startsWith('--filter='));
const filterPatterns = filterArg
  ? filterArg
      .slice('--filter='.length)
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
  : null;
const keepOutputArg = process.argv.find((a) => a.startsWith('--keep-output='));
const keepOutputDir = keepOutputArg
  ? resolve(keepOutputArg.slice('--keep-output='.length))
  : undefined;
const jsonArg = process.argv.find((a) => a.startsWith('--json='));
const jsonPath = jsonArg ? resolve(jsonArg.slice('--json='.length)) : undefined;
// --deep: opt-in. CI 기본 동작 영향 없음.
const deepMode = process.argv.includes('--deep');
// --minify-all: fixture 가 minify=false 여도 강제로 minify 적용. minify가 dead code 를
// 잘못 잘라내는지, 변수 mangling 이 라이브러리 동작을 깨는지 드러남.
const forceMinify = process.argv.includes('--minify-all');
// --format-cjs: 모든 fixture 를 CJS 출력으로 빌드 시도. ESM-only 라이브러리는 fail 가능.
const forceCjs = process.argv.includes('--format-cjs');
const filteredProjects = filterPatterns
  ? projects.filter((p) => filterPatterns.some((pattern) => p.name.includes(pattern)))
  : projects;

if (keepOutputDir) {
  mkdirSync(keepOutputDir, { recursive: true });
}

const results: SmokeResult[] = [];

for (const p of filteredProjects) {
  process.stdout.write(`Testing ${p.name}... `);
  const r = testProject(p, { keepOutputDir, deep: deepMode, forceMinify, forceCjs });
  results.push(r);

  const status = r.zntc.build ? 'OK' : 'FAIL';
  const sizeKB = r.zntc.size > 0 ? `${Math.round(r.zntc.size / 1024)}KB` : '-';
  const match = r.outputMatch ? '' : r.zntc.build && r.esbuild.build ? ' [OUTPUT MISMATCH]' : '';
  console.log(`${status} (${sizeKB}, ${r.zntc.time}ms)${match}`);

  if (r.errors.length > 0) {
    for (const e of r.errors) {
      console.log(`  ERROR: ${e.slice(0, 200)}`);
    }
  }
}

// Summary table
function fmtSize(size: number): string {
  if (size <= 0) return '-';
  const kb = size / 1024;
  return kb >= 10 ? `${Math.round(kb)}KB` : `${kb.toFixed(1)}KB`;
}
function fmtStatus(build: boolean): string {
  return build ? 'OK' : 'FAIL';
}

console.log('\n### Smoke Test Results\n');
console.log(
  '| Project | ZNTC | Size | Time | esbuild | Size | Time | rolldown | Size | Time | rspack | Size | Time | Output |',
);
console.log(
  '|---------|-----|------|------|---------|------|------|----------|------|------|--------|------|------|--------|',
);
for (const r of results) {
  const match =
    !r.zntc.build || (!r.esbuild.build && !r.rolldown.build)
      ? '-'
      : r.outputMatch
        ? 'MATCH'
        : 'DIFF';
  console.log(
    `| ${r.project} | ${fmtStatus(r.zntc.build)} | ${fmtSize(r.zntc.size)} | ${r.zntc.time}ms | ${fmtStatus(r.esbuild.build)} | ${fmtSize(r.esbuild.size)} | ${r.esbuild.time}ms | ${fmtStatus(r.rolldown.build)} | ${fmtSize(r.rolldown.size)} | ${r.rolldown.time}ms | ${fmtStatus(r.rspack.build)} | ${fmtSize(r.rspack.size)} | ${r.rspack.time}ms | ${match} |`,
  );
}

const passed = results.filter((r) => r.zntc.build).length;
const matched = results.filter((r) => r.outputMatch).length;
const comparable = results.filter(
  (r) => r.zntc.build && (r.esbuild.build || r.rolldown.build),
).length;
const total = results.length;
console.log(`\n${passed}/${total} projects built successfully.`);
console.log(`${matched}/${comparable} outputs match baseline.`);

// Size comparison dashboard — ZNTC는 esbuild/rolldown/rspack 중 가장 작은 결과를 baseline 으로
// 비교한다. 가장 빡센 기준이라 셋 중 어느 하나라도 더 작아지면 격차가 즉시 드러난다.
type SizeComparison = {
  name: string;
  zntc: number;
  baselineName: 'esbuild' | 'rolldown' | 'rspack';
  baselineSize: number;
  ratio: number;
};

const sizeComparisons: SizeComparison[] = results
  .filter((r) => r.zntc.build && r.zntc.size > 0)
  .flatMap((r) => {
    const candidates: { name: SizeComparison['baselineName']; size: number }[] = [];
    if (r.esbuild.build && r.esbuild.size > 0)
      candidates.push({ name: 'esbuild', size: r.esbuild.size });
    if (r.rolldown.build && r.rolldown.size > 0)
      candidates.push({ name: 'rolldown', size: r.rolldown.size });
    if (r.rspack.build && r.rspack.size > 0)
      candidates.push({ name: 'rspack', size: r.rspack.size });
    if (candidates.length === 0) return [];
    const best = candidates.reduce((a, b) => (b.size < a.size ? b : a));
    return [
      {
        name: r.project,
        zntc: r.zntc.size,
        baselineName: best.name,
        baselineSize: best.size,
        ratio: r.zntc.size / best.size,
      },
    ];
  })
  .sort((a, b) => b.ratio - a.ratio);

if (sizeComparisons.length > 0) {
  console.log('\n### Size Comparison (ZNTC vs smallest of esbuild/rolldown/rspack)\n');
  console.log('| Project | ZNTC | esbuild | rolldown | rspack | Baseline | Ratio | Status |');
  console.log('|---------|-----|---------|----------|--------|----------|-------|--------|');
  for (const c of sizeComparisons) {
    const r = results.find((r) => r.project === c.name)!;
    const status = c.ratio <= 1.1 ? '✅' : c.ratio <= 1.5 ? '⚠️' : '❌';
    console.log(
      `| ${c.name} | ${fmtSize(c.zntc)} | ${fmtSize(r.esbuild.size)} | ${fmtSize(r.rolldown.size)} | ${fmtSize(r.rspack.size)} | ${c.baselineName} | ${c.ratio.toFixed(2)}x | ${status} |`,
    );
  }
  const avgRatio = sizeComparisons.reduce((s, c) => s + c.ratio, 0) / sizeComparisons.length;
  const smaller = sizeComparisons.filter((c) => c.ratio < 1).length;
  const similar = sizeComparisons.filter((c) => c.ratio >= 1 && c.ratio <= 1.1).length;
  const larger = sizeComparisons.filter((c) => c.ratio > 1.1).length;
  console.log(
    `\nAverage ratio (vs smallest): ${avgRatio.toFixed(2)}x | Smaller: ${smaller} | Similar(±10%): ${similar} | Larger: ${larger}`,
  );
}

if (jsonPath) {
  mkdirSync(dirname(jsonPath), { recursive: true });
  writeFileSync(
    jsonPath,
    JSON.stringify(
      {
        generatedAt: new Date().toISOString(),
        filter: filterPatterns,
        keepOutputDir,
        results,
        sizeComparisons,
      },
      null,
      2,
    ),
  );
}

if (passed < total) {
  process.exit(1);
}
