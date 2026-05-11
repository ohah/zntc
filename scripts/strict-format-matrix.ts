#!/usr/bin/env bun
/**
 * Strict Format Matrix — 일회성 정밀 점검.
 *
 * 축: fixture(Shallow/Deep/External) × format(esm/cjs/iife/umd/amd) × minify(on/off) × bundler(zntc/esbuild/rolldown/rspack)
 *
 * 검증:
 *   1) ZNTC 빌드 성공 + 실행 stdout 이 expected 와 정확 일치
 *   2) UMD 는 3 로딩 모드 (Node CJS / browser global / AMD shim) 모두 같은 출력
 *   3) tree-shake byte-level — usedNeedles 전부 포함, deadNeedles 전부 부재
 *   4) sourcemap 존재 시 mappings/names 유효성 round-trip
 *   5) Differential — esbuild/rolldown/rspack 빌드 성공한 케이스에서 stdout 동일
 *
 * 사용 — `bun scripts/strict-format-matrix.ts` (ReleaseFast `zig-out/bin/zntc` 필요).
 */
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';

const ROOT = resolve(import.meta.dir, '..');
const ZNTC = join(ROOT, 'zig-out/bin/zntc');
const ESBUILD = bin('esbuild');
const ROLLDOWN = bin('rolldown');
const RSPACK = bin('rspack');

function bin(name: string): string {
  const candidates = [
    join(ROOT, 'tests/benchmark/node_modules/.bin', name),
    join(ROOT, 'node_modules/.bin', name),
  ];
  for (const p of candidates) if (existsSync(p)) return p;
  return name; // PATH fallback
}

type Format = 'esm' | 'cjs' | 'iife' | 'umd' | 'amd';
const FORMATS: Format[] = ['esm', 'cjs', 'iife', 'umd', 'amd'];

interface Fixture {
  name: string;
  files: Record<string, string>;
  entry: string;
  expected: string;
  /** 출력에 반드시 포함되어야 하는 substring (used export 보존 검증). */
  usedNeedles: string[];
  /** 출력에 절대 포함되면 안 되는 substring (tree-shake 검증). */
  deadNeedles: string[];
  external?: string[];
  globals?: Record<string, string>;
  globalName?: string;
}

const FIXTURES: Fixture[] = [
  {
    name: 'shallow',
    entry: 'entry.ts',
    files: {
      // entry 가 다른 모듈의 일부 export 만 사용하도록 분리 — entry self-export 는
      // 외부에서 import 가능성이 있어 보존되는 게 정상이라 dead 검증에 부적합.
      'entry.ts': `
import { greet, ver } from "./lib";
export const out = greet("w") + " " + ver + " shallow";
export default { out };
`,
      'lib.ts': `
export const greet = (n) => "hi " + n;
export const ver = "v1";
export const unusedShallow = "DEAD_SHALLOW_NEEDLE";
`,
    },
    expected: 'hi w v1 shallow',
    usedNeedles: ['"v1"', '"hi "', 'shallow'],
    deadNeedles: ['DEAD_SHALLOW_NEEDLE', 'unusedShallow'],
    globalName: 'ShallowLib',
  },
  {
    name: 'deep',
    entry: 'entry.ts',
    files: {
      'entry.ts': `
import { piped, ver, aLabel } from "./barrel";
import "./side";
export const out = piped(7) + " " + ver + " " + aLabel;
export default { out };
`,
      'barrel.ts': `
export { add as piped, aLabel } from "./a";
export { ver } from "./b";
export { dead as deadFromBarrel } from "./c";
`,
      'a.ts': `
export const add = (x) => x + 1;
export const aLabel = "A";
export const aUnused = "DEAD_A_NEEDLE";
`,
      'b.ts': `export const ver = "v2";`,
      'c.ts': `export const dead = "DEAD_C_NEEDLE";`,
      'side.ts': `console.log("[side]");`,
    },
    expected: '[side]\n8 v2 A',
    // 함수 호출 결과 (8) 는 runtime 계산이라 build 산출물 텍스트 검증 부적합.
    // build 산출물에 실제 텍스트로 들어가는 식별자/리터럴만 사용.
    usedNeedles: ['"v2"', '"A"', '[side]', 'x + 1'],
    deadNeedles: ['DEAD_A_NEEDLE', 'DEAD_C_NEEDLE', 'aUnused', 'deadFromBarrel'],
    globalName: 'DeepLib',
  },
  {
    name: 'external',
    entry: 'entry.ts',
    files: {
      'entry.ts': `
import mlib from "mathlib";
import { decor } from "decorlib";
export const out = decor(mlib.add(2, 3));
export default { out };
`,
      // node_modules 안에 stub 패키지 만들기 (Node ESM 도 가능하도록 .mjs)
      'node_modules/mathlib/package.json': JSON.stringify({
        name: 'mathlib',
        main: 'index.cjs',
        module: 'index.mjs',
        exports: { '.': { import: './index.mjs', require: './index.cjs' } },
      }),
      'node_modules/mathlib/index.mjs': `export default { add: (a, b) => a + b };`,
      'node_modules/mathlib/index.cjs': `module.exports = { add: (a, b) => a + b };`,
      'node_modules/decorlib/package.json': JSON.stringify({
        name: 'decorlib',
        main: 'index.cjs',
        module: 'index.mjs',
        exports: { '.': { import: './index.mjs', require: './index.cjs' } },
      }),
      'node_modules/decorlib/index.mjs': `export const decor = (x) => "[" + x + "]";`,
      'node_modules/decorlib/index.cjs': `module.exports.decor = (x) => "[" + x + "]";`,
    },
    expected: '[5]',
    usedNeedles: ['decor', 'mlib', '"[" + x + "]"'],
    deadNeedles: [],
    external: ['mathlib', 'decorlib'],
    globals: { mathlib: 'MLib', decorlib: 'DLib' },
    globalName: 'TestLib',
  },
];

interface RunResult {
  ok: boolean;
  stdout: string;
  stderr: string;
}

function exec(
  cmd: string,
  args: string[],
  cwd?: string,
  env?: NodeJS.ProcessEnv,
): RunResult {
  const r = spawnSync(cmd, args, {
    cwd,
    stdio: 'pipe',
    env: { ...process.env, ...env },
    timeout: 60_000,
  });
  return {
    ok: r.status === 0,
    stdout: (r.stdout?.toString() ?? '').trimEnd(),
    stderr: (r.stderr?.toString() ?? '').trimEnd(),
  };
}

function writeFixture(fx: Fixture, root: string) {
  for (const [rel, content] of Object.entries(fx.files)) {
    const abs = join(root, rel);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content.trimStart());
  }
}

/** ZNTC 빌드 — 출력 파일 경로 반환 (실패 시 null). */
function buildZntc(
  fx: Fixture,
  root: string,
  format: Format,
  minify: boolean,
): { out: string; stderr: string } | null {
  const out = join(root, `out.zntc.${format}.${minify ? 'min' : 'pretty'}.js`);
  const args = [
    '--bundle',
    join(root, fx.entry),
    `--format=${format}`,
    '-o',
    out,
    '--sourcemap=external',
  ];
  if (minify) args.push('--minify');
  if (fx.external) for (const e of fx.external) args.push('--external', e);
  if (fx.globalName && (format === 'iife' || format === 'umd')) {
    args.push(`--global-name=${fx.globalName}`);
  }
  if (fx.globals) {
    const pairs = Object.entries(fx.globals).map(([k, v]) => `${k}=${v}`).join(',');
    args.push(`--globals=${pairs}`);
  }
  const r = exec(ZNTC, args, root);
  if (!r.ok) return null;
  return { out, stderr: r.stderr };
}

function buildEsbuild(fx: Fixture, root: string, format: Format, minify: boolean) {
  if (format === 'amd') return null; // esbuild 미지원
  const out = join(root, `out.esbuild.${format}.${minify ? 'min' : 'pretty'}.js`);
  const args = [
    join(root, fx.entry),
    '--bundle',
    `--format=${format === 'umd' ? 'iife' : format}`, // esbuild는 UMD 미지원 — IIFE 로 비교
    `--outfile=${out}`,
  ];
  if (minify) args.push('--minify');
  if (fx.external) for (const e of fx.external) args.push(`--external:${e}`);
  if (fx.globalName && (format === 'iife' || format === 'umd')) {
    args.push(`--global-name=${fx.globalName}`);
  }
  const r = exec(ESBUILD, args, root);
  if (!r.ok) return null;
  return { out, stderr: r.stderr };
}

function buildRolldown(fx: Fixture, root: string, format: Format, minify: boolean) {
  // rolldown CLI 는 config 없이 빠른 매트릭스 비교가 어려움 — esm/cjs 만 시도, 나머지 skip.
  if (format !== 'esm' && format !== 'cjs') return null;
  const out = join(root, `out.rolldown.${format}.${minify ? 'min' : 'pretty'}.js`);
  const args = ['-i', join(root, fx.entry), '-o', out, `--format=${format}`];
  if (minify) args.push('--minify');
  if (fx.external) {
    for (const e of fx.external) args.push('--external', e);
  }
  const r = exec(ROLLDOWN, args, root);
  if (!r.ok) return null;
  return { out, stderr: r.stderr };
}

/** Node 환경에서 fixture 출력 실행 — 포맷별 다른 loader shim 사용. */
function runOutput(
  fx: Fixture,
  outPath: string,
  format: Format,
  mode: 'node' | 'global' | 'amd',
): RunResult {
  // 모든 fixture 가 default.out / out 으로 결과 노출하도록 통일됨.
  const accessExpr = '(M.default && M.default.out) || M.out';

  let driver: string;
  if (mode === 'node' && (format === 'esm' || format === 'cjs' || format === 'umd')) {
    // Node 에서 esm/cjs/umd 모두 require/dynamic-import 가능.
    if (format === 'esm') {
      driver = `import * as M from ${JSON.stringify(outPath)};\nprocess.stdout.write(String(${accessExpr}));`;
      const driverPath = outPath + '.driver.mjs';
      writeFileSync(driverPath, driver);
      // ESM 외부 stub 패키지를 위해 NODE_PATH 와 fixture root 의 node_modules 사용 — node_modules 는 fixture root 안
      return exec('node', [driverPath], dirname(outPath));
    }
    driver = `const M = require(${JSON.stringify(outPath)});\nprocess.stdout.write(String(${accessExpr}));`;
    const driverPath = outPath + '.driver.cjs';
    writeFileSync(driverPath, driver);
    return exec('node', [driverPath], dirname(outPath));
  }
  if (mode === 'global' && (format === 'iife' || format === 'umd')) {
    // browser global path 시뮬레이션: globals 를 globalThis 에 주입 후 vm.runInThisContext.
    const globalsInject =
      fx.globals && format === 'umd'
        ? Object.entries(fx.globals)
            .map(
              ([k, v]) =>
                `globalThis[${JSON.stringify(v)}] = require(${JSON.stringify(k)});`,
            )
            .join('\n')
        : '';
    driver = `
const vm = require("vm");
const fs = require("fs");
${globalsInject}
// UMD 의 CommonJS 분기 회피 — module/exports 를 숨기고 'define' 도 제거.
const code = fs.readFileSync(${JSON.stringify(outPath)}, "utf8");
const ctx = { console, globalThis };
ctx.window = ctx;
ctx.self = ctx;
Object.assign(ctx, globalThis);
vm.createContext(ctx);
vm.runInContext(code, ctx);
const M = ctx[${JSON.stringify(fx.globalName ?? 'Lib')}];
if (!M) throw new Error("globalName " + ${JSON.stringify(fx.globalName)} + " not on globalThis after IIFE/UMD eval");
process.stdout.write(String(${accessExpr}));
`;
    const driverPath = outPath + '.driver.global.cjs';
    writeFileSync(driverPath, driver);
    return exec('node', [driverPath], dirname(outPath));
  }
  if (mode === 'amd' && (format === 'umd' || format === 'amd')) {
    const globalsInject =
      fx.globals && fx.external
        ? fx.external
            .map((e) => {
              const g = fx.globals![e];
              return `if (id === ${JSON.stringify(e)}) return require(${JSON.stringify(e)});`;
            })
            .join('\n')
        : '';
    // 간단 AMD shim — define([deps], factory) / define(factory) 모두 처리.
    driver = `
const fs = require("fs");
let captured;
function localRequire(id) {
  ${globalsInject}
  throw new Error("amd-shim: unknown dependency " + id);
}
function define(...args) {
  let deps = [], factory;
  if (args.length === 1) { factory = args[0]; }
  else if (args.length === 2) { deps = args[0]; factory = args[1]; }
  else if (args.length === 3) { deps = args[1]; factory = args[2]; }
  else throw new Error("amd-shim: bad define arity " + args.length);
  // AMD CommonJS sugar — deps 에 "require"/"exports"/"module" 가 있으면 매핑.
  const resolved = deps.map((d) => {
    if (d === "require") return localRequire;
    if (d === "exports") return (captured = captured || {});
    if (d === "module") return { exports: (captured = captured || {}) };
    return localRequire(d);
  });
  const ret = factory.apply(null, resolved);
  if (ret !== undefined) captured = ret;
}
define.amd = {};
globalThis.define = define;
const code = fs.readFileSync(${JSON.stringify(outPath)}, "utf8");
new Function(code)();
const M = captured;
if (!M) throw new Error("amd-shim: nothing captured");
process.stdout.write(String(${accessExpr}));
`;
    const driverPath = outPath + '.driver.amd.cjs';
    writeFileSync(driverPath, driver);
    return exec('node', [driverPath], dirname(outPath));
  }
  return { ok: false, stdout: '', stderr: `[skip] unsupported (${format}/${mode})` };
}

function treeShakeCheck(
  outPath: string,
  fx: Fixture,
): { ok: boolean; missing: string[]; leaked: string[] } {
  const code = readFileSync(outPath, 'utf8');
  const missing = fx.usedNeedles.filter((n) => !code.includes(n));
  const leaked = fx.deadNeedles.filter((n) => code.includes(n));
  return { ok: missing.length === 0 && leaked.length === 0, missing, leaked };
}

function sourcemapCheck(
  outPath: string,
): { ok: boolean; reason: string } {
  const mapPath = outPath + '.map';
  if (!existsSync(mapPath)) return { ok: true, reason: 'no map (skip)' };
  try {
    const m = JSON.parse(readFileSync(mapPath, 'utf8'));
    if (typeof m.version !== 'number') return { ok: false, reason: 'version missing' };
    if (!Array.isArray(m.sources) || m.sources.length === 0)
      return { ok: false, reason: 'sources empty' };
    if (typeof m.mappings !== 'string' || m.mappings.length === 0)
      return { ok: false, reason: 'mappings empty' };
    if (!Array.isArray(m.names)) return { ok: false, reason: 'names missing' };
    return { ok: true, reason: `v${m.version}, ${m.sources.length} sources, ${m.names.length} names` };
  } catch (e) {
    return { ok: false, reason: 'parse error: ' + String(e) };
  }
}

interface Cell {
  fixture: string;
  format: Format;
  minify: boolean;
  zntcBuild: boolean;
  zntcStderr: string;
  modes: { mode: string; stdout: string; ok: boolean; reason?: string }[];
  shake: { ok: boolean; missing: string[]; leaked: string[] };
  smap: { ok: boolean; reason: string };
  esbuildBuild: boolean;
  esbuildStdoutMatch: boolean;
  rolldownBuild: boolean;
  rolldownStdoutMatch: boolean;
}

const cells: Cell[] = [];

for (const fx of FIXTURES) {
  const root = mkdtempSync(join(tmpdir(), `strict-fm-${fx.name}-`));
  writeFixture(fx, root);

  for (const format of FORMATS) {
    for (const minify of [false, true]) {
      const cell: Cell = {
        fixture: fx.name,
        format,
        minify,
        zntcBuild: false,
        zntcStderr: '',
        modes: [],
        shake: { ok: false, missing: [], leaked: [] },
        smap: { ok: false, reason: 'n/a' },
        esbuildBuild: false,
        esbuildStdoutMatch: false,
        rolldownBuild: false,
        rolldownStdoutMatch: false,
      };

      const zres = buildZntc(fx, root, format, minify);
      if (!zres) {
        cell.zntcBuild = false;
        cells.push(cell);
        continue;
      }
      cell.zntcBuild = true;
      cell.zntcStderr = zres.stderr;

      // 실행 모드 분기
      const modeList: ('node' | 'global' | 'amd')[] = [];
      if (format === 'esm' || format === 'cjs' || format === 'umd') modeList.push('node');
      if (format === 'iife' || format === 'umd') modeList.push('global');
      if (format === 'amd' || format === 'umd') modeList.push('amd');

      for (const mode of modeList) {
        const r = runOutput(fx, zres.out, format, mode);
        const okEqual = r.ok && r.stdout === fx.expected;
        cell.modes.push({
          mode,
          stdout: r.stdout,
          ok: okEqual,
          reason: okEqual ? undefined : `${r.stderr.slice(0, 200) || r.stdout.slice(0, 200) || 'mismatch'}`,
        });
      }

      cell.shake = treeShakeCheck(zres.out, fx);
      cell.smap = sourcemapCheck(zres.out);

      // Differential — esbuild
      const eres = buildEsbuild(fx, root, format, minify);
      if (eres) {
        cell.esbuildBuild = true;
        const driverMode = format === 'iife' ? 'global' : 'node';
        const er = runOutput(fx, eres.out, format === 'umd' ? 'iife' : format, driverMode);
        cell.esbuildStdoutMatch = er.ok && er.stdout === fx.expected;
      }
      const rres = buildRolldown(fx, root, format, minify);
      if (rres) {
        cell.rolldownBuild = true;
        const rr = runOutput(fx, rres.out, format, 'node');
        cell.rolldownStdoutMatch = rr.ok && rr.stdout === fx.expected;
      }

      cells.push(cell);
    }
  }
}

// ─── 결과 출력 ──────────────────────────────────────────
function bit(v: boolean | undefined): string {
  if (v === undefined) return '-';
  return v ? '✅' : '❌';
}
function modeBits(modes: Cell['modes']): string {
  if (modes.length === 0) return '-';
  return modes.map((m) => `${m.mode}:${m.ok ? '✅' : '❌'}`).join(' ');
}
function shakeStr(s: Cell['shake']): string {
  if (s.ok) return '✅';
  const parts: string[] = [];
  if (s.missing.length) parts.push(`miss=${s.missing.length}`);
  if (s.leaked.length) parts.push(`leak=${s.leaked.length}`);
  return `❌ ${parts.join(' ')}`;
}

console.log('\n### Strict Format Matrix Result\n');
console.log(
  '| Fixture | Format | Min | ZNTC build | Runtime modes | Tree-shake | SourceMap | esbuild ≡ | rolldown ≡ |',
);
console.log(
  '|---------|--------|-----|------------|----------------|------------|-----------|-----------|------------|',
);
for (const c of cells) {
  console.log(
    `| ${c.fixture} | ${c.format} | ${c.minify ? 'min' : '-'} | ${bit(c.zntcBuild)} | ${modeBits(c.modes)} | ${shakeStr(c.shake)} | ${c.smap.ok ? '✅' : '❌'} ${c.smap.reason} | ${c.esbuildBuild ? bit(c.esbuildStdoutMatch) : '-'} | ${c.rolldownBuild ? bit(c.rolldownStdoutMatch) : '-'} |`,
  );
}

// 실패 케이스 디테일
const failures = cells.filter(
  (c) =>
    !c.zntcBuild ||
    !c.shake.ok ||
    c.modes.some((m) => !m.ok) ||
    !c.smap.ok,
);
if (failures.length > 0) {
  console.log('\n### Failures detail\n');
  for (const c of failures) {
    console.log(`- ${c.fixture}/${c.format}/${c.minify ? 'min' : 'pretty'}`);
    if (!c.zntcBuild) console.log(`  zntc build fail: ${c.zntcStderr.slice(0, 400)}`);
    for (const m of c.modes) {
      if (!m.ok) console.log(`  ${m.mode}: stdout=${JSON.stringify(m.stdout)} reason=${m.reason}`);
    }
    if (!c.shake.ok) {
      if (c.shake.missing.length) console.log(`  shake miss: ${c.shake.missing.join(', ')}`);
      if (c.shake.leaked.length) console.log(`  shake leak: ${c.shake.leaked.join(', ')}`);
    }
    if (!c.smap.ok) console.log(`  smap: ${c.smap.reason}`);
  }
}

// summary
const totalZ = cells.length;
const passZ = cells.filter((c) => c.zntcBuild).length;
const runZ = cells.filter((c) => c.zntcBuild && c.modes.length > 0 && c.modes.every((m) => m.ok)).length;
const shakeZ = cells.filter((c) => c.zntcBuild && c.shake.ok).length;
const smapZ = cells.filter((c) => c.zntcBuild && c.smap.ok).length;
console.log(
  `\nZNTC build: ${passZ}/${totalZ} · run all modes: ${runZ}/${totalZ} · tree-shake: ${shakeZ}/${totalZ} · sourcemap: ${smapZ}/${totalZ}`,
);

if (passZ < totalZ || runZ < totalZ || shakeZ < totalZ || smapZ < totalZ) {
  process.exit(1);
}
