#!/usr/bin/env bun
/**
 * ZTS Smoke Test — 실제 프로젝트 빌드+실행 검증
 *
 * npm에서 실제 라이브러리를 설치하고 ZTS/esbuild/rolldown으로 번들링하여
 * 1) 빌드 성공  2) 실행 성공  3) 출력 일치 여부를 비교한다.
 *
 * esbuild 출력을 기준(baseline)으로 ZTS/rolldown 출력이 동일한지 검증.
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, existsSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
// bun workspace hoisting: devDependencies가 루트 node_modules에 설치될 수 있음
const ESBUILD_BIN = existsSync(join(__dirname, "node_modules/.bin/esbuild"))
  ? join(__dirname, "node_modules/.bin/esbuild")
  : join(ROOT, "node_modules/.bin/esbuild");
const ROLLDOWN_BIN = existsSync(join(__dirname, "node_modules/.bin/rolldown"))
  ? join(__dirname, "node_modules/.bin/rolldown")
  : join(ROOT, "node_modules/.bin/rolldown");
const RSPACK_BIN = existsSync(join(__dirname, "node_modules/.bin/rspack"))
  ? join(__dirname, "node_modules/.bin/rspack")
  : join(ROOT, "node_modules/.bin/rspack");

interface BundlerResult {
  build: boolean;
  size: number;
  time: number;
  stdout: string;
}

interface SmokeResult {
  project: string;
  zts: BundlerResult;
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
  const r = spawnSync(bin, args, { cwd, stdio: "pipe", timeout: 120000 });
  const time = Math.round(performance.now() - start);
  const stdout = r.stdout?.toString().trim() ?? "";
  const stderr = r.stderr?.toString() ?? "";
  return { ok: r.status === 0, stdout, stderr, time };
}

function fileSize(path: string): number {
  try {
    return statSync(path).size;
  } catch {
    return 0;
  }
}

const emptyResult: BundlerResult = { build: false, size: 0, time: 0, stdout: "" };

/** 단일 번들러로 빌드 + 실행하고 결과 반환 */
function bundleAndRun(
  bin: string,
  buildArgs: string[],
  outFile: string,
  cwd?: string,
): BundlerResult {
  const build = exec(bin, buildArgs, cwd);
  if (!build.ok) {
    return { build: false, size: 0, time: build.time, stdout: "" };
  }
  const run = exec("node", [outFile]);
  return {
    build: run.ok,
    size: fileSize(outFile),
    time: build.time,
    stdout: run.ok ? run.stdout : "",
  };
}

interface ProjectConfig {
  name: string;
  pkg: string;
  entry: string;
  external?: string[];
  format?: "esm" | "cjs";
  platform?: "node" | "browser";
  tsconfig?: Record<string, boolean>;
  target?: string; // --target=es5, --target=es2015, etc.
}

function testProject(p: ProjectConfig): SmokeResult {
  const dir = mkdtempSync(join(tmpdir(), `zts-smoke-${p.name}-`));
  const result: SmokeResult = {
    project: p.name,
    zts: { ...emptyResult },
    esbuild: { ...emptyResult },
    rolldown: { ...emptyResult },
    rspack: { ...emptyResult },
    outputMatch: false,
    errors: [],
  };

  // entry 파일을 benchmark 디렉토리에 작성 (node_modules resolve를 위해)
  const entryFile = join(__dirname, `_smoke_entry_${p.name}.ts`);
  try {
    writeFileSync(entryFile, p.entry);

    // tsconfig.json 생성 (decorator 등 옵션이 필요한 경우)
    const tsconfigFile = join(__dirname, `_smoke_tsconfig_${p.name}.json`);
    if (p.tsconfig) {
      writeFileSync(tsconfigFile, JSON.stringify({ compilerOptions: p.tsconfig }));
    }

    const ztsOut = join(dir, "dist-zts.js");
    const esOut = join(dir, "dist-esbuild.js");
    const rdOut = join(dir, "dist-rolldown.js");
    const ext = p.external ?? [];
    const format = p.format ?? "esm";
    const platform = p.platform ?? "node";

    // ZTS
    const ztsExternalArgs = ext.flatMap((e) => ["--external", e]);
    const ztsFormatArgs = format === "cjs" ? ["--format=cjs"] : [];
    const ztsTsconfigArgs = p.tsconfig ? ["-p", tsconfigFile] : [];
    const ztsTargetArgs = p.target ? [`--target=${p.target}`] : [];
    result.zts = bundleAndRun(
      ZTS_BIN,
      [
        "--bundle",
        entryFile,
        "-o",
        ztsOut,
        `--platform=${platform}`,
        ...ztsExternalArgs,
        ...ztsFormatArgs,
        ...ztsTsconfigArgs,
        ...ztsTargetArgs,
      ],
      ztsOut,
    );
    if (!result.zts.build && result.zts.size === 0) {
      result.errors.push(`ZTS: build or run failed`);
    }

    // esbuild
    if (existsSync(ESBUILD_BIN)) {
      const esExternalArgs = ext.flatMap((e) => [`--external:${e}`]);
      const esFormatArgs = format === "esm" ? [`--format=esm`] : [];
      const esTargetArgs = p.target ? [`--target=${p.target}`] : [];
      result.esbuild = bundleAndRun(
        ESBUILD_BIN,
        [
          entryFile,
          "--bundle",
          `--outfile=${esOut}`,
          "--loader:.ts=ts",
          `--platform=${platform}`,
          ...esExternalArgs,
          ...esFormatArgs,
          ...esTargetArgs,
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
      const rdExternalArgs = ext.flatMap((e) => ["--external", e]);
      result.rolldown = bundleAndRun(
        ROLLDOWN_BIN,
        [entryFile, "-o", rdOut, "--format", "cjs", "--platform", platform, ...rdExternalArgs],
        rdOut,
        __dirname,
      );
      if (!result.rolldown.build) {
        result.errors.push(`rolldown: build or run failed`);
      }
    }

    // rspack (config 파일 생성 — CLI만으로는 target/externals 설정 불가)
    if (existsSync(RSPACK_BIN) && !p.target) {
      const rsOut = join(dir, "dist-rspack");
      const rsConfigPath = join(__dirname, `_rspack_config_${p.name}.cjs`);
      const rsConfig = `module.exports = {
        entry: ${JSON.stringify(entryFile)},
        output: { path: ${JSON.stringify(rsOut)}, filename: "main.js" },
        target: ${JSON.stringify(platform === "node" ? "node" : "web")},
        mode: "production",
        optimization: { minimize: false },
        module: { rules: [{ test: /\\.ts$/, use: { loader: "builtin:swc-loader", options: { jsc: { parser: { syntax: "typescript" } } } } }] },
        ${ext.length > 0 ? `externals: ${JSON.stringify(ext)},` : ""}
      };`;
      writeFileSync(rsConfigPath, rsConfig);
      result.rspack = bundleAndRun(
        RSPACK_BIN,
        ["build", "-c", rsConfigPath],
        join(rsOut, "main.js"),
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
    if (result.zts.build && result.esbuild.build) {
      result.outputMatch = result.zts.stdout === result.esbuild.stdout;
      if (!result.outputMatch) {
        result.errors.push(
          `Output mismatch:\n  ZTS:     ${result.zts.stdout.slice(0, 100)}\n  esbuild: ${result.esbuild.stdout.slice(0, 100)}`,
        );
      }
    } else if (result.zts.build && result.rolldown.build) {
      // esbuild 실패 시 rolldown과 비교
      result.outputMatch = result.zts.stdout === result.rolldown.stdout;
      if (!result.outputMatch) {
        result.errors.push(
          `Output mismatch:\n  ZTS:      ${result.zts.stdout.slice(0, 100)}\n  rolldown: ${result.rolldown.stdout.slice(0, 100)}`,
        );
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
    try {
      rmSync(entryFile);
    } catch {}
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
    name: "lodash-es",
    pkg: "lodash-es",
    entry: `import { groupBy, sortBy, uniq } from 'lodash-es';\nconsole.log(groupBy, sortBy, uniq);`,
  },
  {
    name: "preact",
    pkg: "preact",
    entry: `import { h, render } from 'preact';\nconsole.log(h, render);`,
  },
  {
    name: "date-fns",
    pkg: "date-fns",
    entry: `import { format, addDays } from 'date-fns';\nconsole.log(format(addDays(new Date(), 1), 'yyyy-MM-dd'));`,
  },
  {
    name: "uuid",
    pkg: "uuid",
    entry: `import { v4 } from 'uuid';\nconst id = v4();\nconsole.log(typeof id, id.length);`,
  },
  {
    name: "zod",
    pkg: "zod",
    entry: `import { z } from 'zod';\nconst schema = z.string().email();\nconsole.log(schema.parse('test@test.com'));`,
  },
  {
    name: "axios",
    pkg: "axios",
    entry: `import axios from 'axios';\nconsole.log(typeof axios.get, typeof axios.post, typeof axios.create);`,
  },
  {
    name: "toolkit",
    pkg: "@reduxjs/toolkit react redux",
    entry: `import { configureStore, createSlice } from '@reduxjs/toolkit';\nconst slice = createSlice({ name: 'test', initialState: 0, reducers: { inc: s => s + 1 } });\nconsole.log(slice.name, typeof slice.reducer);`,
  },
  {
    name: "rxjs",
    pkg: "rxjs",
    entry: `import { of, map, filter, toArray } from 'rxjs';\nof(1,2,3,4,5).pipe(filter(x=>x%2===0), map(x=>x*10), toArray()).subscribe(arr=>console.log(JSON.stringify(arr)));`,
  },
  {
    name: "immer",
    pkg: "immer",
    entry: `import { produce } from 'immer';\nconst o = { a: 1, b: [1,2] };\nconst n = produce(o, d => { d.a = 2; d.b.push(3); });\nconsole.log(o.a, n.a, o === n);`,
  },
  {
    name: "superjson",
    pkg: "superjson",
    entry: `import superjson from 'superjson';\nconst d = { s: new Set([1,2]), m: new Map([['a',1]]) };\nconst r = superjson.parse(superjson.stringify(d)) as typeof d;\nconsole.log(r.s instanceof Set, r.m instanceof Map);`,
  },
  {
    name: "express",
    pkg: "express",
    entry: `import express from 'express';\nconst app = express();\napp.get('/t', (q,s)=>s.json({ok:true}));\nconsole.log(typeof app.listen, typeof app.get);`,
  },
  {
    name: "react",
    pkg: "react",
    entry: `import React from 'react';\nconst el = React.createElement('div', {id:'t'}, 'hi');\nconsole.log(el.type, el.props.id);`,
  },
  {
    name: "commander",
    pkg: "commander",
    entry: `import { Command } from 'commander';\nconst p = new Command();\np.option('-n, --name <str>', 'name').parse(['node', 'test', '--name', 'hello']);\nconsole.log(p.opts().name);`,
  },
  {
    name: "eventemitter3",
    pkg: "eventemitter3",
    entry: `import EE from 'eventemitter3';\nconst e = new EE();\nlet v = 0;\ne.on('x', (n: number) => v = n);\ne.emit('x', 42);\nconsole.log(v);`,
  },
  {
    name: "ms",
    pkg: "ms",
    entry: `import ms from 'ms';\nconsole.log(ms('2 days'), ms(60000));`,
  },
  {
    name: "dotenv",
    pkg: "dotenv",
    entry: `import dotenv from 'dotenv';\nconsole.log(typeof dotenv.config, typeof dotenv.parse);`,
  },
  {
    name: "jsonwebtoken",
    pkg: "jsonwebtoken",
    entry: `import jwt from 'jsonwebtoken';\nconst t = jwt.sign({uid:1},'secret');\nconst d = jwt.verify(t,'secret') as any;\nconsole.log(d.uid);`,
  },
  {
    name: "bcryptjs",
    pkg: "bcryptjs",
    entry: `import bcrypt from 'bcryptjs';\nconst h = bcrypt.hashSync('pw', 4);\nconsole.log(bcrypt.compareSync('pw', h));`,
  },
  {
    name: "clsx",
    pkg: "clsx",
    entry: `import { clsx } from 'clsx';\nconsole.log(clsx('a', false, 'b', {c:true, d:false}, ['e']));`,
  },
  {
    name: "tiny-invariant",
    pkg: "tiny-invariant",
    entry: `import invariant from 'tiny-invariant';\ninvariant(true, 'ok');\nconsole.log('pass');`,
  },
  {
    name: "tanstack-query",
    pkg: "@tanstack/query-core",
    entry: `import { QueryClient } from '@tanstack/query-core';\nconst qc = new QueryClient();\nqc.fetchQuery({queryKey:['t'],queryFn:()=>Promise.resolve(42)}).then(r=>{console.log(r);qc.clear();});`,
  },
  {
    name: "fast-glob",
    pkg: "fast-glob",
    entry: `import fg from 'fast-glob';\nconsole.log(typeof fg, typeof fg.sync);`,
  },
  {
    name: "micromatch",
    pkg: "micromatch",
    entry: `import mm from 'micromatch';\nconsole.log(mm(['foo.js','bar.ts','baz.js'], '*.js'));`,
  },
  {
    name: "semver",
    pkg: "semver",
    entry: `import semver from 'semver';\nconsole.log(semver.gt('2.0.0','1.0.0'), semver.valid('1.2.3'));`,
  },
  {
    name: "debug",
    pkg: "debug",
    entry: `import debug from 'debug';\nconst log = debug('test');\nconsole.log(typeof log);`,
  },
  {
    name: "chalk",
    pkg: "chalk@5",
    entry: `import chalk from 'chalk';\nconsole.log(chalk.red('hello'));`,
  },
  {
    name: "yaml",
    pkg: "yaml",
    entry: `import { parse } from 'yaml';\nconsole.log(JSON.stringify(parse('a: 1\\nb: 2')));`,
  },
  {
    name: "yargs",
    pkg: "yargs",
    entry: `import yargs from 'yargs';\nconsole.log(typeof yargs);`,
    format: "cjs",
  },
  {
    name: "effect",
    pkg: "effect",
    entry: `import { Effect, pipe } from 'effect';\nconst p = pipe(Effect.succeed(42), Effect.map((n: number) => n + 1));\nEffect.runPromise(p).then(r => console.log(r));`,
  },
  {
    name: "vue",
    pkg: "vue",
    entry: `import { ref, computed } from 'vue';\nconst c = ref(0);\nconst d = computed(() => c.value * 2);\nconsole.log(c.value, d.value);`,
  },
  {
    name: "svelte",
    pkg: "svelte",
    entry: `import { readable } from 'svelte/store';\nconst t = readable(0, set => { set(42); return () => {}; });\nlet v; t.subscribe(x => v = x);\nconsole.log(v);`,
  },
  // svelte tree-shaking 스펙트럼. `platform: "browser"`가 필수 — svelte의
  // package.json `exports` 조건부 resolve가 node에서는 서버 stub
  // (`index-server.js`, mount가 throw stub만)을 내주고, browser에서만 풀 client
  // runtime(`index-client.js`)을 내주기 때문이다. node 기본으로 돌리면 #1567/#1626
  // 회귀 지표가 전혀 드러나지 않는다. 엔트리는 DOM을 건드리지 않아 node로도 실행 가능.
  {
    // core 5개 API — reactivity + effect + props 서브시스템 대부분 reachable.
    name: "svelte-mount",
    pkg: "svelte",
    platform: "browser",
    entry: `import { mount, unmount, untrack, tick, flushSync } from 'svelte';\nconsole.log([mount, unmount, untrack, tick, flushSync].map(f => typeof f).join(','));`,
  },
  {
    // 광범위 surface — lifecycle + context + store까지 끌어옴.
    name: "svelte-full",
    pkg: "svelte",
    platform: "browser",
    entry: `import { mount, unmount, untrack, tick, flushSync, onMount, onDestroy, getContext, setContext, hasContext } from 'svelte';\nimport { readable, writable, derived } from 'svelte/store';\nconsole.log([mount, unmount, untrack, tick, flushSync, onMount, onDestroy, getContext, setContext, hasContext, readable, writable, derived].map(f => typeof f).join(','));`,
  },
  {
    name: "solid-js",
    pkg: "solid-js",
    entry: `import { createSignal } from 'solid-js';\nconst [count, setCount] = createSignal(0);\nsetCount(1);\nconsole.log(count());`,
  },
  {
    name: "three",
    pkg: "three",
    entry: `import { Vector3 } from 'three';\nconst v = new Vector3(1, 2, 3);\nconsole.log(v.length().toFixed(2));`,
  },
  {
    name: "graphql",
    pkg: "graphql",
    entry: `import { parse } from 'graphql';\nconst d = parse('{ hello }');\nconsole.log(d.definitions[0].selectionSet.selections[0].name.value);`,
  },
  {
    name: "supabase",
    pkg: "@supabase/supabase-js",
    entry: `import { createClient } from '@supabase/supabase-js';\nconsole.log(typeof createClient);`,
  },
  {
    name: "mobx",
    pkg: "mobx",
    entry: `import { observable } from 'mobx';\nconst o = observable({ v: 0 });\no.v = 42;\nconsole.log(o.v);`,
  },
  {
    name: "jotai",
    pkg: "jotai react",
    entry: `import { atom, createStore } from 'jotai';\nconst a = atom(0);\nconst s = createStore();\ns.set(a, 42);\nconsole.log(s.get(a));`,
    external: ["react"],
  },
  {
    name: "mitt",
    pkg: "mitt",
    entry: `import mitt from 'mitt';\nconst e = mitt();\nlet v = 0;\ne.on('x', (n) => v = n);\ne.emit('x', 42);\nconsole.log(v);`,
  },
  {
    name: "zustand",
    pkg: "zustand",
    entry: `import { createStore } from 'zustand/vanilla';\nconst store = createStore((set) => ({ count: 0, inc: () => set((s) => ({ count: s.count + 1 })) }));\nstore.getState().inc();\nconsole.log(store.getState().count);`,
  },
  {
    name: "valtio",
    pkg: "valtio",
    entry: `import { proxy, snapshot } from 'valtio/vanilla';\nconst state = proxy({ count: 0 });\nstate.count = 42;\nconsole.log(snapshot(state).count);`,
  },
  {
    name: "react-dom",
    pkg: "react-dom react",
    entry: `import { renderToString } from 'react-dom/server';\nimport { createElement } from 'react';\nconsole.log(renderToString(createElement('div', null, 'Hello')));`,
  },
  {
    name: "d3",
    pkg: "d3",
    entry: `import { scaleLinear, range } from 'd3';\nconst s = scaleLinear().domain([0, 100]).range([0, 1]);\nconsole.log(s(50));`,
  },
  {
    name: "hono",
    pkg: "hono",
    entry: `import { Hono } from 'hono';\nconst app = new Hono();\napp.get('/', (c) => c.text('Hello'));\nconsole.log('routes:', app.routes.length);`,
  },
  {
    name: "dayjs",
    pkg: "dayjs",
    entry: `import dayjs from 'dayjs';\nconsole.log(dayjs('2024-01-01').format('YYYY/MM/DD'));`,
  },
  {
    name: "nanoid",
    pkg: "nanoid",
    entry: `import { nanoid } from 'nanoid';\nconsole.log(nanoid().length >= 21);`,
  },
  {
    name: "zlib",
    pkg: "pako",
    entry: `import pako from 'pako';\nconst d = pako.deflate('hello world');\nconsole.log(pako.inflate(d, { to: 'string' }));`,
  },
  {
    name: "fp-ts",
    pkg: "fp-ts",
    entry: `import { pipe } from 'fp-ts/function';\nimport { some, map, getOrElse } from 'fp-ts/Option';\nconst r = pipe(some(1), map((n: number) => n + 1), getOrElse(() => 0));\nconsole.log(r);`,
  },
  {
    name: "neverthrow",
    pkg: "neverthrow",
    entry: `import { ok, err } from 'neverthrow';\nconst r = ok(42).map((n: number) => n + 1);\nconsole.log(r.isOk(), r.isOk() ? r.value : null);`,
  },
  {
    name: "drizzle-orm",
    pkg: "drizzle-orm",
    entry: `import { sql } from 'drizzle-orm';\nconsole.log(typeof sql);`,
  },
  // --- 추가 패키지 ---
  {
    name: "tslib",
    pkg: "tslib",
    entry: `import { __awaiter } from 'tslib';\nconsole.log(typeof __awaiter);`,
  },
  {
    name: "iconv-lite",
    pkg: "iconv-lite",
    entry: `import iconv from 'iconv-lite';\nconsole.log(typeof iconv.encode);`,
  },
  {
    name: "qs",
    pkg: "qs",
    entry: `import qs from 'qs';\nconsole.log(qs.stringify({ a: 1, b: 2 }));`,
  },
  {
    name: "change-case",
    pkg: "change-case",
    entry: `import { camelCase } from 'change-case';\nconsole.log(camelCase('hello-world'));`,
  },
  {
    name: "path-to-regexp",
    pkg: "path-to-regexp",
    entry: `import { match } from 'path-to-regexp';\nconst fn = match('/user/:id');\nconsole.log(typeof fn);`,
  },
  {
    name: "mime-types",
    pkg: "mime-types",
    entry: `import mime from 'mime-types';\nconsole.log(mime.lookup('test.js'));`,
  },
  {
    name: "ajv",
    pkg: "ajv",
    entry: `import Ajv from 'ajv';\nconst ajv = new Ajv();\nconst v = ajv.compile({type:'number'});\nconsole.log(v(42));`,
  },
  {
    name: "cac",
    pkg: "cac",
    entry: `import cac from 'cac';\nconst cli = cac('test');\nconsole.log(typeof cli.parse);`,
  },
  {
    name: "defu",
    pkg: "defu",
    entry: `import { defu } from 'defu';\nconsole.log(JSON.stringify(defu({ a: 1 }, { a: 2, b: 3 })));`,
  },
  {
    name: "pathe",
    pkg: "pathe",
    entry: `import { join } from 'pathe';\nconsole.log(join('a', 'b', 'c'));`,
  },
  {
    name: "destr",
    pkg: "destr",
    entry: `import { destr } from 'destr';\nconsole.log(destr('{"a":1}').a);`,
  },
  {
    name: "hookable",
    pkg: "hookable",
    entry: `import { createHooks } from 'hookable';\nconst hooks = createHooks();\nconsole.log(typeof hooks.hook);`,
  },
  {
    name: "minimatch",
    pkg: "minimatch",
    entry: `import { minimatch } from 'minimatch';\nconsole.log(minimatch('foo.js', '*.js'));`,
  },
  {
    name: "cheerio",
    pkg: "cheerio",
    entry: `import { load } from 'cheerio';\nconst doc = load('<h1>Hello</h1>');\nconsole.log(doc('h1').text());`,
  },
  // --- 추가 패키지 (소형 유틸리티) ---
  {
    name: "is-glob",
    pkg: "is-glob",
    entry: `import isGlob from 'is-glob';\nconsole.log(isGlob('*.js'));`,
  },
  {
    name: "glob-parent",
    pkg: "glob-parent",
    entry: `import gp from 'glob-parent';\nconsole.log(gp('a/b/*.js'));`,
  },
  {
    name: "escape-string-regexp",
    pkg: "escape-string-regexp",
    entry: `import esc from 'escape-string-regexp';\nconsole.log(esc('a.b'));`,
  },
  {
    name: "fast-deep-equal",
    pkg: "fast-deep-equal",
    entry: `import eq from 'fast-deep-equal';\nconsole.log(eq({ a: 1 }, { a: 1 }));`,
  },
  {
    name: "deepmerge",
    pkg: "deepmerge",
    entry: `import dm from 'deepmerge';\nconsole.log(JSON.stringify(dm({ a: 1 }, { b: 2 })));`,
  },
  {
    name: "color-convert",
    pkg: "color-convert",
    entry: `import c from 'color-convert';\nconsole.log(c.rgb.hex(255, 0, 0));`,
  },
  {
    name: "picomatch",
    pkg: "picomatch",
    entry: `import pm from 'picomatch';\nconsole.log(pm.isMatch('foo.js', '*.js'));`,
  },
  {
    name: "type-is",
    pkg: "type-is",
    entry: `import typeis from 'type-is';\nconsole.log(typeof typeis);`,
  },
  {
    name: "object-assign",
    pkg: "object-assign",
    entry: `import oa from 'object-assign';\nconsole.log(typeof oa);`,
  },
  {
    name: "has-flag",
    pkg: "has-flag",
    entry: `import hf from 'has-flag';\nconsole.log(typeof hf);`,
  },
  {
    name: "p-limit",
    pkg: "p-limit",
    entry: `import pLimit from 'p-limit';\nconst l = pLimit(1);\nconsole.log(typeof l);`,
  },
  {
    name: "strip-ansi",
    pkg: "strip-ansi",
    entry: `import strip from 'strip-ansi';\nconsole.log(strip('hello'));`,
  },
  {
    name: "ansi-regex",
    pkg: "ansi-regex",
    entry: `import ar from 'ansi-regex';\nconsole.log(typeof ar);`,
  },
  {
    name: "wrap-ansi",
    pkg: "wrap-ansi",
    entry: `import wrap from 'wrap-ansi';\nconsole.log(typeof wrap);`,
  },
  {
    name: "supports-color",
    pkg: "supports-color",
    entry: `import sc from 'supports-color';\nconsole.log(typeof sc);`,
  },
  {
    name: "cross-spawn",
    pkg: "cross-spawn",
    entry: `import cs from 'cross-spawn';\nconsole.log(typeof cs.spawn);`,
  },
  {
    name: "lru-cache",
    pkg: "lru-cache",
    entry: `import { LRUCache } from 'lru-cache';\nconst c = new LRUCache({ max: 10 });\nc.set('a', 1);\nconsole.log(c.get('a'));`,
  },
  {
    name: "signal-exit",
    pkg: "signal-exit",
    entry: `import { onExit } from 'signal-exit';\nconsole.log(typeof onExit);`,
  },
  {
    name: "which",
    pkg: "which",
    entry: `import which from 'which';\nconsole.log(typeof which);`,
  },
  {
    name: "string-width",
    pkg: "string-width",
    entry: `import sw from 'string-width';\nconsole.log(sw('hello'));`,
  },
  // --- 추가 패키지 (CJS 유틸리티 + 마이크로 라이브러리) ---
  {
    name: "safe-buffer",
    pkg: "safe-buffer",
    entry: `import { Buffer } from 'safe-buffer';\nconsole.log(Buffer.alloc(4).length);`,
  },
  {
    name: "bytes",
    pkg: "bytes",
    entry: `import bytes from 'bytes';\nconsole.log(bytes(1024));`,
  },
  {
    name: "depd",
    pkg: "depd",
    entry: `import depd from 'depd';\nconsole.log(typeof depd);`,
  },
  {
    name: "merge-descriptors",
    pkg: "merge-descriptors",
    entry: `import md from 'merge-descriptors';\nconsole.log(typeof md);`,
  },
  {
    name: "content-type",
    pkg: "content-type",
    entry: `import ct from 'content-type';\nconsole.log(ct.parse('text/html').type);`,
  },
  {
    name: "cookie",
    pkg: "cookie",
    entry: `import { serialize } from 'cookie';\nconsole.log(serialize('a', 'b'));`,
  },
  {
    name: "on-finished",
    pkg: "on-finished",
    entry: `import onf from 'on-finished';\nconsole.log(typeof onf);`,
  },
  {
    name: "statuses",
    pkg: "statuses",
    entry: `import statuses from 'statuses';\nconsole.log(statuses(200));`,
  },
  {
    name: "etag",
    pkg: "etag",
    entry: `import etag from 'etag';\nconsole.log(etag('hello').length > 0);`,
  },
  {
    name: "vary",
    pkg: "vary",
    entry: `import vary from 'vary';\nconsole.log(typeof vary);`,
  },
  {
    name: "flat",
    pkg: "flat",
    entry: `import { flatten } from 'flat';\nconsole.log(JSON.stringify(flatten({ a: { b: 1 } })));`,
  },
  {
    name: "retry",
    pkg: "retry",
    entry: `import retry from 'retry';\nconsole.log(typeof retry.createTimeout);`,
  },
  {
    name: "camelcase",
    pkg: "camelcase",
    entry: `import cc from 'camelcase';\nconsole.log(cc('foo-bar'));`,
  },
  {
    name: "decamelize",
    pkg: "decamelize",
    entry: `import dc from 'decamelize';\nconsole.log(dc('fooBar'));`,
  },
  {
    name: "memoize-one",
    pkg: "memoize-one",
    entry: `import mo from 'memoize-one';\nconst fn = mo((a: number) => a * 2);\nconsole.log(fn(5));`,
  },
  {
    name: "rfdc",
    pkg: "rfdc",
    entry: `import rfdc from 'rfdc';\nconst clone = rfdc();\nconsole.log(JSON.stringify(clone({ a: 1 })));`,
  },
  {
    name: "ohash",
    pkg: "ohash",
    entry: `import { hash } from 'ohash';\nconsole.log(typeof hash({ a: 1 }));`,
  },
  {
    name: "nanoevents",
    pkg: "nanoevents",
    entry: `import { createNanoEvents } from 'nanoevents';\nconst e = createNanoEvents();\nconsole.log(typeof e.on);`,
  },
  // zx: CJS 래핑 모듈 내부의 require("async_hooks")가 ESM 번들에서 동작 안 함
  // → createRequire(import.meta.url) 주입 필요 (esbuild 방식)

  // ============================================================
  // TypeScript-heavy 패키지 — TS→JS 트랜스파일 정확도 검증
  // ============================================================
  {
    name: "typebox",
    pkg: "@sinclair/typebox",
    entry: `import { Type } from '@sinclair/typebox';\nconst T = Type.Object({ name: Type.String(), age: Type.Number() });\nconsole.log(JSON.stringify(T.type));`,
  },
  {
    name: "ts-pattern",
    pkg: "ts-pattern",
    entry: `import { match, P } from 'ts-pattern';\nconst r = match({ type: 'ok', value: 42 }).with({ type: 'ok', value: P.number }, (v) => v.value * 2).otherwise(() => 0);\nconsole.log(r);`,
  },
  {
    name: "valibot",
    pkg: "valibot",
    entry: `import * as v from 'valibot';\nconst schema = v.object({ name: v.string(), age: v.number() });\nconst r = v.parse(schema, { name: 'Alice', age: 30 });\nconsole.log(r.name, r.age);`,
  },
  {
    name: "ts-results-es",
    pkg: "ts-results-es",
    entry: `import { Ok } from 'ts-results-es';\nconst r = new Ok(42).map(n => n + 1);\nconsole.log(r.isOk(), r.value);`,
  },
  {
    name: "remeda",
    pkg: "remeda",
    entry: `import { pipe, map, filter } from 'remeda';\nconst r = pipe([1,2,3,4,5], filter((x: number) => x > 1), map((x: number) => x * 2));\nconsole.log(JSON.stringify(r));`,
  },
  {
    name: "nanostores",
    pkg: "nanostores",
    entry: `import { atom, computed } from 'nanostores';\nconst count = atom(0);\nconst doubled = computed(count, (v) => v * 2);\ncount.set(5);\nconsole.log(doubled.get());`,
  },
  {
    name: "ky",
    pkg: "ky",
    entry: `import ky from 'ky';\nconsole.log(typeof ky.get, typeof ky.post, typeof ky.create);`,
  },
  // typedi: 번들러 decorator 변환 미지원 → Container API만 검증
  {
    name: "typedi",
    pkg: "typedi",
    entry: `import { Container, Token } from 'typedi';\nconst MY_TOKEN = new Token('MY_VALUE');\nContainer.set(MY_TOKEN, 42);\nconsole.log(Container.get(MY_TOKEN));`,
  },
  {
    name: "io-ts",
    pkg: "io-ts fp-ts",
    entry: `import * as t from 'io-ts';\nconst User = t.type({ name: t.string, age: t.number });\nconst r = User.decode({ name: 'Alice', age: 30 });\nconsole.log(r._tag);`,
  },
  {
    name: "type-fest",
    pkg: "type-fest",
    entry: `import type { CamelCase } from 'type-fest';\nconst x = 'hello';\nconsole.log(x);`,
  },
  {
    name: "arktype",
    pkg: "arktype",
    entry: `import { type } from 'arktype';\nconst user = type({ name: 'string', age: 'number' });\nconsole.log(typeof user);`,
  },
  {
    name: "kysely",
    pkg: "kysely",
    entry: `import { Kysely, DummyDriver, SqliteAdapter, SqliteIntrospector, SqliteQueryCompiler } from 'kysely';\nconst db = new Kysely({ dialect: { createAdapter: () => new SqliteAdapter(), createDriver: () => new DummyDriver(), createIntrospector: (db) => new SqliteIntrospector(db), createQueryCompiler: () => new SqliteQueryCompiler() } });\nconsole.log(typeof db.selectFrom);`,
  },

  // ============================================================
  // 다운레벨링 스모크 테스트 — 각 ES 타겟별 실제 패키지 빌드+실행
  // ============================================================

  // --- target=es5 (ES2015 전체 다운레벨링) ---
  {
    name: "lodash-es@es5",
    pkg: "lodash-es",
    entry: `import { uniq, sortBy } from 'lodash-es';\nconsole.log(JSON.stringify(uniq([1,2,2,3])));`,
    target: "es5",
  },
  {
    name: "clsx@es5",
    pkg: "clsx",
    entry: `import { clsx } from 'clsx';\nconsole.log(clsx('a', false, 'b', {c:true}));`,
    target: "es5",
  },
  {
    name: "ms@es5",
    pkg: "ms",
    entry: `import ms from 'ms';\nconsole.log(ms('2 days'));`,
    target: "es5",
  },
  {
    name: "deepmerge@es5",
    pkg: "deepmerge",
    entry: `import dm from 'deepmerge';\nconsole.log(JSON.stringify(dm({a:1},{b:2})));`,
    target: "es5",
  },
  {
    name: "fast-deep-equal@es5",
    pkg: "fast-deep-equal",
    entry: `import eq from 'fast-deep-equal';\nconsole.log(eq({a:1},{a:1}));`,
    target: "es5",
  },
  {
    name: "semver@es5",
    pkg: "semver",
    entry: `import semver from 'semver';\nconsole.log(semver.gt('2.0.0','1.0.0'));`,
    target: "es5",
  },

  // --- target=es2015 (ES2016 다운레벨링: **) ---
  {
    name: "lodash-es@es2015",
    pkg: "lodash-es",
    entry: `import { uniq } from 'lodash-es';\nconsole.log(JSON.stringify(uniq([1,2,2,3])));`,
    target: "es2015",
  },
  {
    name: "superjson@es2015",
    pkg: "superjson",
    entry: `import superjson from 'superjson';\nconsole.log(superjson.stringify({a:1}));`,
    target: "es2015",
  },

  // --- target=es2017 (ES2018 다운레벨링: object spread) ---
  {
    name: "flat@es2017",
    pkg: "flat",
    entry: `import { flatten } from 'flat';\nconsole.log(JSON.stringify(flatten({a:{b:1}})));`,
    target: "es2017",
  },
  {
    name: "defu@es2017",
    pkg: "defu",
    entry: `import { defu } from 'defu';\nconsole.log(JSON.stringify(defu({a:1},{a:2,b:3})));`,
    target: "es2017",
  },

  // --- target=es2018 (ES2019 다운레벨링: optional catch) ---
  {
    name: "picomatch@es2018",
    pkg: "picomatch",
    entry: `import pm from 'picomatch';\nconsole.log(pm.isMatch('foo.js', '*.js'));`,
    target: "es2018",
  },

  // --- target=es2019 (ES2020 다운레벨링: ??, ?.) ---
  {
    name: "semver@es2019",
    pkg: "semver",
    entry: `import semver from 'semver';\nconsole.log(semver.gt('2.0.0','1.0.0'));`,
    target: "es2019",
  },
  {
    name: "clsx@es2019",
    pkg: "clsx",
    entry: `import { clsx } from 'clsx';\nconsole.log(clsx('a', false, 'b'));`,
    target: "es2019",
  },
  {
    name: "nanoid@es2019",
    pkg: "nanoid",
    entry: `import { nanoid } from 'nanoid';\nconsole.log(nanoid().length >= 21);`,
    target: "es2019",
  },

  // --- target=es2020 (ES2021 다운레벨링: ??=, ||=, &&=) ---
  {
    name: "dayjs@es2020",
    pkg: "dayjs",
    entry: `import dayjs from 'dayjs';\nconsole.log(dayjs('2024-01-01').format('YYYY/MM/DD'));`,
    target: "es2020",
  },
  {
    name: "ohash@es2020",
    pkg: "ohash",
    entry: `import { hash } from 'ohash';\nconsole.log(typeof hash({a:1}));`,
    target: "es2020",
  },

  // --- target=es2021 (ES2022 다운레벨링: static block, class fields) ---
  {
    name: "lru-cache@es2021",
    pkg: "lru-cache",
    entry: `import { LRUCache } from 'lru-cache';\nconst c = new LRUCache({max:10});\nc.set('a',1);\nconsole.log(c.get('a'));`,
    target: "es2021",
  },
  {
    name: "nanostores@es2021",
    pkg: "nanostores",
    entry: `import { atom } from 'nanostores';\nconst c = atom(0);\nc.set(42);\nconsole.log(c.get());`,
    target: "es2021",
  },

  // ============================================================
  // Engine target tests — --target=chrome80,safari14 등
  // ============================================================
  {
    name: "lodash-es@chrome80",
    pkg: "lodash-es",
    entry: `import { groupBy, sortBy, uniq } from 'lodash-es';\nconsole.log(groupBy, sortBy, uniq);`,
    target: "chrome80",
  },
  {
    name: "clsx@chrome49",
    pkg: "clsx",
    entry: `import { clsx } from 'clsx';\nconsole.log(clsx('a', false, 'b', {c:true}));`,
    target: "chrome49",
  },
  {
    name: "dayjs@safari14",
    pkg: "dayjs",
    entry: `import dayjs from 'dayjs';\nconsole.log(dayjs().format('YYYY-MM-DD'));`,
    target: "safari14",
  },
  {
    name: "nanoid@node16",
    pkg: "nanoid",
    entry: `import { nanoid } from 'nanoid';\nconsole.log(nanoid());`,
    target: "node16",
    platform: "node",
  },
];

// ============================================================
// Run
// ============================================================

console.log("ZTS Smoke Test — Real Project Bundling\n");

// CLI: --filter=<패턴> 으로 이름 필터링 (예: --filter=@es5, --filter=lodash)
const filterArg = process.argv.find((a) => a.startsWith("--filter="));
const filterPattern = filterArg ? filterArg.split("=")[1] : null;
const filteredProjects = filterPattern
  ? projects.filter((p) => p.name.includes(filterPattern))
  : projects;

const results: SmokeResult[] = [];

for (const p of filteredProjects) {
  process.stdout.write(`Testing ${p.name}... `);
  const r = testProject(p);
  results.push(r);

  const status = r.zts.build ? "OK" : "FAIL";
  const sizeKB = r.zts.size > 0 ? `${Math.round(r.zts.size / 1024)}KB` : "-";
  const match = r.outputMatch ? "" : r.zts.build && r.esbuild.build ? " [OUTPUT MISMATCH]" : "";
  console.log(`${status} (${sizeKB}, ${r.zts.time}ms)${match}`);

  if (r.errors.length > 0) {
    for (const e of r.errors) {
      console.log(`  ERROR: ${e.slice(0, 200)}`);
    }
  }
}

// Summary table
function fmtSize(size: number): string {
  if (size <= 0) return "-";
  const kb = size / 1024;
  return kb >= 10 ? `${Math.round(kb)}KB` : `${kb.toFixed(1)}KB`;
}
function fmtStatus(build: boolean): string {
  return build ? "OK" : "FAIL";
}

console.log("\n### Smoke Test Results\n");
console.log(
  "| Project | ZTS | Size | Time | esbuild | Size | Time | rolldown | Size | Time | rspack | Size | Time | Output |",
);
console.log(
  "|---------|-----|------|------|---------|------|------|----------|------|------|--------|------|------|--------|",
);
for (const r of results) {
  const match =
    !r.zts.build || (!r.esbuild.build && !r.rolldown.build)
      ? "-"
      : r.outputMatch
        ? "MATCH"
        : "DIFF";
  console.log(
    `| ${r.project} | ${fmtStatus(r.zts.build)} | ${fmtSize(r.zts.size)} | ${r.zts.time}ms | ${fmtStatus(r.esbuild.build)} | ${fmtSize(r.esbuild.size)} | ${r.esbuild.time}ms | ${fmtStatus(r.rolldown.build)} | ${fmtSize(r.rolldown.size)} | ${r.rolldown.time}ms | ${fmtStatus(r.rspack.build)} | ${fmtSize(r.rspack.size)} | ${r.rspack.time}ms | ${match} |`,
  );
}

const passed = results.filter((r) => r.zts.build).length;
const matched = results.filter((r) => r.outputMatch).length;
const comparable = results.filter(
  (r) => r.zts.build && (r.esbuild.build || r.rolldown.build),
).length;
const total = results.length;
console.log(`\n${passed}/${total} projects built successfully.`);
console.log(`${matched}/${comparable} outputs match baseline.`);

// Size comparison dashboard
const sizeComparisons = results
  .filter((r) => r.zts.build && r.esbuild.build && r.zts.size > 0 && r.esbuild.size > 0)
  .map((r) => ({
    name: r.project,
    zts: r.zts.size,
    esbuild: r.esbuild.size,
    ratio: r.zts.size / r.esbuild.size,
  }))
  .sort((a, b) => b.ratio - a.ratio);

if (sizeComparisons.length > 0) {
  console.log("\n### Size Comparison (ZTS vs esbuild)\n");
  console.log("| Project | ZTS | esbuild | rolldown | rspack | Ratio | Status |");
  console.log("|---------|-----|---------|----------|--------|-------|--------|");
  for (const c of sizeComparisons) {
    const r = results.find((r) => r.project === c.name)!;
    const status = c.ratio <= 1.1 ? "✅" : c.ratio <= 1.5 ? "⚠️" : "❌";
    console.log(
      `| ${c.name} | ${fmtSize(c.zts)} | ${fmtSize(c.esbuild)} | ${fmtSize(r.rolldown.size)} | ${fmtSize(r.rspack.size)} | ${c.ratio.toFixed(2)}x | ${status} |`,
    );
  }
  const avgRatio = sizeComparisons.reduce((s, c) => s + c.ratio, 0) / sizeComparisons.length;
  const smaller = sizeComparisons.filter((c) => c.ratio < 1).length;
  const similar = sizeComparisons.filter((c) => c.ratio >= 1 && c.ratio <= 1.1).length;
  const larger = sizeComparisons.filter((c) => c.ratio > 1.1).length;
  console.log(
    `\nAverage ratio: ${avgRatio.toFixed(2)}x | Smaller: ${smaller} | Similar(±10%): ${similar} | Larger: ${larger}`,
  );
}

if (passed < total) {
  process.exit(1);
}
