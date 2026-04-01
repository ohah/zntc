import { test, expect } from "@playwright/test";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile, mkdir, readFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve, extname } from "node:path";

const ZTS_BIN = resolve(__dirname, "../../../zig-out/bin/zts");

interface BrowserSmokeCase {
  name: string;
  pkg: string;
  entry: string;
  expected: string;
  extraArgs?: string[];
}

/**
 * 브라우저 스모크 테스트 — ZTS로 --platform=browser 번들링 후
 * Playwright에서 실제 브라우저로 실행하여 console.log 출력 검증.
 *
 * Node.js 전용 패키지(express, jsonwebtoken 등)는 제외.
 * process.env.NODE_ENV를 참조하는 패키지는 --define으로 치환.
 */
const cases: BrowserSmokeCase[] = [
  {
    name: "lodash-es",
    pkg: "lodash-es",
    entry: `import { uniq } from 'lodash-es';\nconsole.log(JSON.stringify(uniq([1,2,2,3])));`,
    expected: "[1,2,3]",
  },
  {
    name: "preact",
    pkg: "preact",
    entry: `import { h } from 'preact';\nconsole.log(typeof h);`,
    expected: "function",
  },
  {
    name: "immer",
    pkg: "immer",
    entry: `import { produce } from 'immer';\nconst n = produce({ a: 1 }, d => { d.a = 2; });\nconsole.log(n.a);`,
    expected: "2",
  },
  {
    name: "mobx",
    pkg: "mobx",
    entry: `import { observable } from 'mobx';\nconst o = observable({ v: 0 });\no.v = 42;\nconsole.log(o.v);`,
    expected: "42",
  },
  {
    name: "clsx",
    pkg: "clsx",
    entry: `import { clsx } from 'clsx';\nconsole.log(clsx('a', false, 'b'));`,
    expected: "a b",
  },
  {
    name: "ms",
    pkg: "ms",
    entry: `import ms from 'ms';\nconsole.log(ms('2 days'));`,
    expected: "172800000",
  },
  {
    name: "eventemitter3",
    pkg: "eventemitter3",
    entry: `import EE from 'eventemitter3';\nconst e = new EE();\nlet v = 0;\ne.on('x', (n) => v = n);\ne.emit('x', 42);\nconsole.log(v);`,
    expected: "42",
  },
  {
    name: "three",
    pkg: "three",
    entry: `import { Vector3 } from 'three';\nconst v = new Vector3(1, 2, 3);\nconsole.log(v.length().toFixed(2));`,
    expected: "3.74",
  },
  {
    name: "dayjs",
    pkg: "dayjs",
    entry: `import dayjs from 'dayjs';\nconsole.log(dayjs('2024-01-01').format('YYYY/MM/DD'));`,
    expected: "2024/01/01",
  },
  {
    name: "nanoid",
    pkg: "nanoid",
    entry: `import { nanoid } from 'nanoid';\nconsole.log(nanoid().length >= 21);`,
    expected: "true",
  },
  {
    name: "zod",
    pkg: "zod",
    entry: `import { z } from 'zod';\nconsole.log(typeof z.string);`,
    expected: "function",
  },
  {
    name: "superjson",
    pkg: "superjson",
    entry: `import superjson from 'superjson';\nconsole.log(typeof superjson.stringify);`,
    expected: "function",
  },
  {
    name: "date-fns",
    pkg: "date-fns",
    entry: `import { addDays } from 'date-fns';\nconsole.log(typeof addDays);`,
    expected: "function",
  },
  {
    name: "d3",
    pkg: "d3",
    entry: `import { scaleLinear } from 'd3';\nconsole.log(scaleLinear().domain([0, 1]).range([0, 10])(0.5));`,
    expected: "5",
  },
  {
    name: "pako",
    pkg: "pako",
    entry: `import pako from 'pako';\nconsole.log(typeof pako.deflate);`,
    expected: "function",
  },
  {
    name: "solid-js",
    pkg: "solid-js",
    entry: `import { createSignal } from 'solid-js';\nconst [count, setCount] = createSignal(0);\nsetCount(1);\nconsole.log(count());`,
    expected: "1",
  },
  {
    name: "vue",
    pkg: "vue",
    entry: `import { ref } from 'vue';\nconsole.log(ref(0).value);`,
    expected: "0",
  },
  {
    name: "svelte",
    pkg: "svelte",
    entry: `import { readable } from 'svelte/store';\nlet v;\nreadable(42, s => { s(42); return () => {}; }).subscribe(x => v = x);\nconsole.log(v);`,
    expected: "42",
  },
  {
    name: "react",
    pkg: "react",
    entry: `import React from 'react';\nconsole.log(typeof React.createElement);`,
    expected: "function",
  },
  {
    name: "graphql",
    pkg: "graphql",
    entry: `import { parse } from 'graphql';\nconsole.log(parse('{ hello }').definitions.length);`,
    expected: "1",
  },
  {
    name: "uuid",
    pkg: "uuid",
    entry: `import { v4 } from 'uuid';\nconsole.log(typeof v4(), v4().length);`,
    expected: "string 36",
  },
  {
    name: "rxjs",
    pkg: "rxjs",
    entry: `import { of, map, toArray } from 'rxjs';\nof(1,2,3).pipe(map(x=>x*10), toArray()).subscribe(arr=>console.log(JSON.stringify(arr)));`,
    expected: "[10,20,30]",
  },
  {
    name: "tiny-invariant",
    pkg: "tiny-invariant",
    entry: `import invariant from 'tiny-invariant';\ninvariant(true, 'ok');\nconsole.log('pass');`,
    expected: "pass",
  },
  {
    name: "tanstack-query",
    pkg: "@tanstack/query-core",
    entry: `import { QueryClient } from '@tanstack/query-core';\nconst qc = new QueryClient();\nconsole.log(typeof qc.fetchQuery);`,
    expected: "function",
  },
  {
    name: "effect",
    pkg: "effect",
    entry: `import { Effect, pipe } from 'effect';\nconst p = pipe(Effect.succeed(42), Effect.map((n) => n + 1));\nEffect.runPromise(p).then(r => console.log(r));`,
    expected: "43",
  },
  {
    name: "minimatch",
    pkg: "minimatch",
    entry: `import { minimatch } from 'minimatch';\nconsole.log(minimatch('foo.js', '*.js'));`,
    expected: "true",
  },
  {
    name: "fast-deep-equal",
    pkg: "fast-deep-equal",
    entry: `import eq from 'fast-deep-equal';\nconsole.log(eq({ a: 1 }, { a: 1 }));`,
    expected: "true",
  },
  {
    name: "deepmerge",
    pkg: "deepmerge",
    entry: `import dm from 'deepmerge';\nconsole.log(JSON.stringify(dm({ a: 1 }, { b: 2 })));`,
    expected: '{"a":1,"b":2}',
  },
  {
    name: "picomatch",
    pkg: "picomatch",
    entry: `import pm from 'picomatch';\nconsole.log(pm.isMatch('foo.js', '*.js'));`,
    expected: "true",
  },
  {
    name: "camelcase",
    pkg: "camelcase",
    entry: `import cc from 'camelcase';\nconsole.log(cc('foo-bar'));`,
    expected: "fooBar",
  },
  {
    name: "memoize-one",
    pkg: "memoize-one",
    entry: `import mo from 'memoize-one';\nconst fn = mo((a) => a * 2);\nconsole.log(fn(5));`,
    expected: "10",
  },
  {
    name: "nanoevents",
    pkg: "nanoevents",
    entry: `import { createNanoEvents } from 'nanoevents';\nconst e = createNanoEvents();\nconsole.log(typeof e.on);`,
    expected: "function",
  },
  {
    name: "ohash",
    pkg: "ohash",
    entry: `import { hash } from 'ohash';\nconsole.log(typeof hash({ a: 1 }));`,
    expected: "string",
  },
  {
    name: "neverthrow",
    pkg: "neverthrow",
    entry: `import { ok } from 'neverthrow';\nconst r = ok(42).map(n => n + 1);\nconsole.log(r.isOk(), r._unsafeUnwrap());`,
    expected: "true 43",
  },
  {
    name: "yaml",
    pkg: "yaml",
    entry: `import { parse } from 'yaml';\nconsole.log(JSON.stringify(parse('a: 1\\nb: 2')));`,
    expected: '{"a":1,"b":2}',
  },
  {
    name: "semver",
    pkg: "semver",
    entry: `import semver from 'semver';\nconsole.log(semver.gt('2.0.0', '1.0.0'));`,
    expected: "true",
  },
  {
    name: "hono",
    pkg: "hono",
    entry: `import { Hono } from 'hono';\nconst app = new Hono();\napp.get('/', (c) => c.text('Hello'));\nconsole.log('routes:', app.routes.length);`,
    expected: "routes: 1",
  },
  {
    name: "chalk",
    pkg: "chalk@5",
    entry: `import chalk from 'chalk';\nconsole.log(typeof chalk.red);`,
    expected: "function",
  },
  {
    name: "drizzle-orm",
    pkg: "drizzle-orm",
    entry: `import { sql } from 'drizzle-orm';\nconsole.log(typeof sql);`,
    expected: "function",
  },
  {
    name: "react-dom",
    pkg: "react-dom@18 react@18",
    entry: `import { renderToString } from 'react-dom/server';\nimport { createElement } from 'react';\nconsole.log(renderToString(createElement('div', null, 'Hello')));`,
    expected: "<div>Hello</div>",
  },
  // --- 추가 브라우저 호환 패키지 ---
  {
    name: "ajv",
    pkg: "ajv",
    entry: `import Ajv from 'ajv';\nconst a = new Ajv();\nconsole.log(typeof a.compile);`,
    expected: "function",
  },
  {
    name: "change-case",
    pkg: "change-case",
    entry: `import { camelCase } from 'change-case';\nconsole.log(camelCase('foo-bar'));`,
    expected: "fooBar",
  },
  {
    name: "escape-string-regexp",
    pkg: "escape-string-regexp",
    entry: `import esc from 'escape-string-regexp';\nconsole.log(esc('a.b'));`,
    expected: "a\\.b",
  },
  {
    name: "is-glob",
    pkg: "is-glob",
    entry: `import isGlob from 'is-glob';\nconsole.log(isGlob('*.js'));`,
    expected: "true",
  },
  {
    name: "flat",
    pkg: "flat",
    entry: `import { flatten } from 'flat';\nconsole.log(JSON.stringify(flatten({ a: { b: 1 } })));`,
    expected: '{"a.b":1}',
  },
  {
    name: "decamelize",
    pkg: "decamelize",
    entry: `import dc from 'decamelize';\nconsole.log(dc('fooBar'));`,
    expected: "foo_bar",
  },
  {
    name: "rfdc",
    pkg: "rfdc",
    entry: `import rfdc from 'rfdc';\nconsole.log(JSON.stringify(rfdc()({ a: 1 })));`,
    expected: '{"a":1}',
  },
  {
    name: "defu",
    pkg: "defu",
    entry: `import { defu } from 'defu';\nconsole.log(JSON.stringify(defu({ a: 1 }, { b: 2 })));`,
    expected: '{"b":2,"a":1}',
  },
  {
    name: "destr",
    pkg: "destr",
    entry: `import { destr } from 'destr';\nconsole.log(typeof destr);`,
    expected: "function",
  },
  {
    name: "hookable",
    pkg: "hookable",
    entry: `import { createHooks } from 'hookable';\nconsole.log(typeof createHooks);`,
    expected: "function",
  },
  {
    name: "pathe",
    pkg: "pathe",
    entry: `import { join } from 'pathe';\nconsole.log(join('a', 'b'));`,
    expected: "a/b",
  },
  {
    name: "cac",
    pkg: "cac",
    entry: `import cac from 'cac';\nconsole.log(typeof cac);`,
    expected: "function",
  },
  {
    name: "lru-cache",
    pkg: "lru-cache",
    entry: `import { LRUCache } from 'lru-cache';\nconst c = new LRUCache({ max: 10 });\nc.set('a', 1);\nconsole.log(c.get('a'));`,
    expected: "1",
  },
  {
    name: "color-convert",
    pkg: "color-convert",
    entry: `import c from 'color-convert';\nconsole.log(c.rgb.hex(255, 0, 0));`,
    expected: "FF0000",
  },
  {
    name: "qs",
    pkg: "qs",
    entry: `import qs from 'qs';\nconsole.log(qs.stringify({ a: 1 }));`,
    expected: "a=1",
  },
  // glob-parent, micromatch: path.dirname 등 Node path API가 필수 — polyfill(--alias) 필요
  {
    name: "cheerio",
    pkg: "cheerio",
    entry: `import { load } from 'cheerio';\nconsole.log(load('<b>hi</b>')('b').text());`,
    expected: "hi",
  },
  // --- smoke.ts에 있지만 browser-smoke에 없던 브라우저 호환 패키지 ---
  {
    name: "supabase",
    pkg: "@supabase/supabase-js",
    entry: `import { createClient } from '@supabase/supabase-js';\nconsole.log(typeof createClient);`,
    expected: "function",
  },
  {
    name: "jotai",
    pkg: "jotai react",
    entry: `import { atom, createStore } from 'jotai';\nconst a = atom(0);\nconst s = createStore();\ns.set(a, 42);\nconsole.log(s.get(a));`,
    expected: "42",
    extraArgs: ["--external", "react"],
  },
  {
    name: "valtio",
    pkg: "valtio",
    entry: `import { proxy, snapshot } from 'valtio/vanilla';\nconst state = proxy({ count: 0 });\nstate.count = 42;\nconsole.log(snapshot(state).count);`,
    expected: "42",
  },
  {
    name: "tslib",
    pkg: "tslib",
    entry: `import { __awaiter } from 'tslib';\nconsole.log(typeof __awaiter);`,
    expected: "function",
  },
  {
    name: "path-to-regexp",
    pkg: "path-to-regexp",
    entry: `import { match } from 'path-to-regexp';\nconsole.log(typeof match);`,
    expected: "function",
  },
  {
    name: "p-limit",
    pkg: "p-limit",
    entry: `import pLimit from 'p-limit';\nconst l = pLimit(1);\nconsole.log(typeof l);`,
    expected: "function",
  },
  {
    name: "debug",
    pkg: "debug",
    entry: `import debug from 'debug';\nconst log = debug('test');\nconsole.log(typeof log);`,
    expected: "function",
  },
  {
    name: "bcryptjs",
    pkg: "bcryptjs",
    entry: `import bcrypt from 'bcryptjs';\nconst h = bcrypt.hashSync('pw', 4);\nconsole.log(bcrypt.compareSync('pw', h));`,
    expected: "true",
  },
  {
    name: "object-assign",
    pkg: "object-assign",
    entry: `import oa from 'object-assign';\nconsole.log(typeof oa);`,
    expected: "function",
  },
  {
    name: "strip-ansi",
    pkg: "strip-ansi",
    entry: `import strip from 'strip-ansi';\nconsole.log(strip('hello'));`,
    expected: "hello",
  },
  {
    name: "ansi-regex",
    pkg: "ansi-regex",
    entry: `import ar from 'ansi-regex';\nconsole.log(typeof ar);`,
    expected: "function",
  },
  {
    name: "content-type",
    pkg: "content-type",
    entry: `import ct from 'content-type';\nconsole.log(ct.parse('text/html').type);`,
    expected: "text/html",
  },
  {
    name: "cookie",
    pkg: "cookie",
    entry: `import { serialize } from 'cookie';\nconsole.log(serialize('a', 'b'));`,
    expected: "a=b",
  },
  {
    name: "statuses",
    pkg: "statuses",
    entry: `import statuses from 'statuses';\nconsole.log(statuses(200));`,
    expected: "OK",
  },
  {
    name: "vary",
    pkg: "vary",
    entry: `import vary from 'vary';\nconsole.log(typeof vary);`,
    expected: "function",
  },
  {
    name: "retry",
    pkg: "retry",
    entry: `import retry from 'retry';\nconsole.log(typeof retry.createTimeout);`,
    expected: "function",
  },
  {
    name: "bytes",
    pkg: "bytes",
    entry: `import bytes from 'bytes';\nconsole.log(bytes(1024));`,
    expected: "1KB",
  },
  {
    name: "merge-descriptors",
    pkg: "merge-descriptors",
    entry: `import md from 'merge-descriptors';\nconsole.log(typeof md);`,
    expected: "function",
  },
  {
    name: "string-width",
    pkg: "string-width",
    entry: `import sw from 'string-width';\nconsole.log(sw('hello'));`,
    expected: "5",
  },
  {
    name: "has-flag",
    pkg: "has-flag",
    entry: `import hf from 'has-flag';\nconsole.log(typeof hf);`,
    expected: "function",
  },
  {
    name: "wrap-ansi",
    pkg: "wrap-ansi",
    entry: `import wrap from 'wrap-ansi';\nconsole.log(typeof wrap);`,
    expected: "function",
  },
  {
    name: "type-is",
    pkg: "type-is",
    entry: `import typeis from 'type-is';\nconsole.log(typeof typeis);`,
    expected: "function",
  },
  // --- smoke.ts에 없는 추가 브라우저 패키지 ---
  {
    name: "dompurify",
    pkg: "dompurify",
    entry: `import DOMPurify from 'dompurify';\nconsole.log(typeof DOMPurify.sanitize);`,
    expected: "function",
  },
  {
    name: "marked",
    pkg: "marked",
    entry: `import { marked } from 'marked';\nconsole.log(marked('**bold**').trim());`,
    expected: "<p><strong>bold</strong></p>",
  },
  {
    name: "highlight.js",
    pkg: "highlight.js",
    entry: `import hljs from 'highlight.js/lib/core';\nconsole.log(typeof hljs.highlight);`,
    expected: "function",
  },
  {
    name: "luxon",
    pkg: "luxon",
    entry: `import { DateTime } from 'luxon';\nconsole.log(DateTime.fromISO('2024-01-01').toFormat('yyyy/MM/dd'));`,
    expected: "2024/01/01",
  },
  {
    name: "big.js",
    pkg: "big.js",
    entry: `import Big from 'big.js';\nconsole.log(new Big(0.1).plus(0.2).toString());`,
    expected: "0.3",
  },
  {
    name: "decimal.js",
    pkg: "decimal.js",
    entry: `import Decimal from 'decimal.js';\nconsole.log(new Decimal(0.1).plus(0.2).toString());`,
    expected: "0.3",
  },
  {
    name: "mitt",
    pkg: "mitt",
    entry: `import mitt from 'mitt';\nconst emitter = mitt();\nlet v = 0;\nemitter.on('x', (n) => v = n);\nemitter.emit('x', 42);\nconsole.log(v);`,
    expected: "42",
  },
  {
    name: "zustand",
    pkg: "zustand",
    entry: `import { createStore } from 'zustand/vanilla';\nconst store = createStore((set) => ({ count: 0, inc: () => set((s) => ({ count: s.count + 1 })) }));\nstore.getState().inc();\nconsole.log(store.getState().count);`,
    expected: "1",
  },
  {
    name: "nanostores",
    pkg: "nanostores",
    entry: `import { atom } from 'nanostores';\nconst count = atom(0);\ncount.set(42);\nconsole.log(count.get());`,
    expected: "42",
  },
  {
    name: "just-debounce-it",
    pkg: "just-debounce-it",
    entry: `import debounce from 'just-debounce-it';\nconsole.log(typeof debounce);`,
    expected: "function",
  },
  {
    name: "just-throttle",
    pkg: "just-throttle",
    entry: `import throttle from 'just-throttle';\nconsole.log(typeof throttle);`,
    expected: "function",
  },
  {
    name: "tinycolor2",
    pkg: "tinycolor2",
    entry: `import tinycolor from 'tinycolor2';\nconsole.log(tinycolor('red').toHexString());`,
    expected: "#ff0000",
  },
  {
    name: "slugify",
    pkg: "slugify",
    entry: `import slugify from 'slugify';\nconsole.log(slugify('Hello World'));`,
    expected: "Hello-World",
  },
  {
    name: "validator",
    pkg: "validator",
    entry: `import validator from 'validator';\nconsole.log(validator.isEmail('a@b.com'));`,
    expected: "true",
  },
  {
    name: "just-safe-get",
    pkg: "just-safe-get",
    entry: `import get from 'just-safe-get';\nconsole.log(get({ a: { b: 1 } }, 'a.b'));`,
    expected: "1",
  },
  {
    name: "json5",
    pkg: "json5",
    entry: `import JSON5 from 'json5';\nconsole.log(JSON.stringify(JSON5.parse('{a:1}')));`,
    expected: '{"a":1}',
  },
  {
    name: "hotscript",
    pkg: "hotscript",
    entry: `import { Pipe } from 'hotscript';\nconsole.log(typeof Pipe);`,
    expected: "undefined",
  },
  // remeda: pipe 함수 인자 수 검증 에러 — ZTS tree-shaking/scope hoisting 버그 (ISSUES.md)
  // --- Node 전용 패키지 (브라우저 스킵) ---
  // express, commander, dotenv, jsonwebtoken, yargs, supports-color,
  // cross-spawn, signal-exit, which, on-finished, fast-glob, zx
];

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
};

function serve(dir: string): Promise<{ server: Server; port: number }> {
  return new Promise((res) => {
    const server = createServer(async (req, resp) => {
      const filePath = join(dir, req.url === "/" ? "index.html" : req.url!);
      try {
        const data = await readFile(filePath);
        resp.writeHead(200, { "Content-Type": MIME[extname(filePath)] ?? "text/plain" });
        resp.end(data);
      } catch {
        resp.writeHead(404);
        resp.end("Not Found");
      }
    });
    server.listen(0, () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      res({ server, port });
    });
  });
}

let fixtureDir: string;

test.beforeAll(async () => {
  fixtureDir = await mkdtemp(join(tmpdir(), "zts-browser-smoke-"));
});

test.afterAll(async () => {
  await rm(fixtureDir, { recursive: true, force: true });
});

for (const c of cases) {
  test(`browser: ${c.name}`, async ({ page }) => {
    const caseDir = join(fixtureDir, c.name);
    await mkdir(caseDir, { recursive: true });

    await writeFile(
      join(caseDir, "package.json"),
      JSON.stringify({ name: `bs-${c.name}`, private: true }),
    );
    const install = spawnSync("npm", ["install", ...c.pkg.split(/\s+/), "--save"], {
      cwd: caseDir,
      stdio: "pipe",
      timeout: 120000,
    });
    expect(
      install.status,
      `npm install ${c.pkg} failed: ${install.stderr?.toString().slice(0, 200)}`,
    ).toBe(0);

    await writeFile(join(caseDir, "index.ts"), c.entry);
    const outFile = join(caseDir, "bundle.js");
    const build = spawnSync(
      ZTS_BIN,
      [
        "--bundle",
        join(caseDir, "index.ts"),
        "-o",
        outFile,
        "--platform=browser",
        ...(c.extraArgs ?? []),
      ],
      { stdio: "pipe", timeout: 30000 },
    );
    expect(build.status, `ZTS build failed: ${build.stderr?.toString().slice(0, 300)}`).toBe(0);

    await writeFile(
      join(caseDir, "index.html"),
      `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body><script src="./bundle.js"></script></body></html>`,
    );

    const { server, port } = await serve(caseDir);
    try {
      const logs: string[] = [];
      page.on("console", (msg) => {
        if (msg.type() === "log") logs.push(msg.text());
      });

      const errors: string[] = [];
      page.on("pageerror", (err) => errors.push(err.message));

      await page.goto(`http://localhost:${port}/`);
      await page.waitForTimeout(1000);

      expect(errors, `Browser errors in ${c.name}: ${errors.join(", ")}`).toHaveLength(0);
      expect(logs.join("\n"), `Expected "${c.expected}" in console output`).toContain(c.expected);
    } finally {
      server.close();
    }
  });
}
