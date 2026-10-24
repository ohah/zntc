import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const inputs = [
  ['sync values', 'const out=[]; for await (const v of [1,2]) out.push(v); return out;'],
  [
    'sync iterator fallback',
    'const source={ [Symbol.iterator]() { let n=0; return {next(){return {value:++n,done:n>2}}}; }}; const out=[]; for await(const v of source) out.push(v); return out;',
  ],
  [
    'iterator close',
    'let closed=0; const source={ [Symbol.iterator]() {return {next(){return {value:3,done:false}},return(){closed++;return {done:true}}}; }}; for await(const v of source) {break;} return closed;',
  ],
  [
    'async iterator',
    'const source={ [Symbol.asyncIterator]() {let n=0;return {async next(){return {value:++n,done:n>2}}}; }}; const out=[]; for await(const v of source) out.push(v); return out;',
  ],
  [
    'generator await',
    'async function* gen(){yield await Promise.resolve(4);yield 5;} const out=[]; for await(const v of gen()) out.push(v); return out;',
  ],
  [
    'generator throw and finally',
    'const events=[]; async function* gen(){try {yield 1;throw new Error("boom");}finally{events.push("finally");}} try{for await(const v of gen()) events.push(v);}catch(e){events.push(e.message);} return events;',
  ],
  [
    'delegate sync',
    'async function* gen(){yield* [6,7];} const out=[]; for await(const v of gen()) out.push(v); return out;',
  ],
  [
    'delegate async',
    'async function* inner(){yield await 8;yield 9;} async function* gen(){yield* inner();} const out=[];for await(const v of gen())out.push(v);return out;',
  ],
  [
    'delegate return',
    'const events=[];async function* inner(){try{yield 10;yield 11;}finally{events.push("closed");}}async function* gen(){yield* inner();}for await(const v of gen()){events.push(v);break;}return events;',
  ],
  [
    'helper name decoys',
    'const __await="decoy",__values="other",$aw=13;async function* gen(){yield* [__await,__values,$aw];}const out=[];for await(const v of gen())out.push(v);return out;',
  ],
] as const;

const bridge = 'async function* bridge(){ yield await Promise.resolve(17); }\n';
const finish =
  'function finish(run){ return Promise.all([run(),bridge().next()]).then(v=>console.log(JSON.stringify(v))); }\n';

describe('runtime helper dependencies start with import identities (#4819)', () => {
  for (const [name, body] of inputs) {
    for (const target of ['es5', 'es2017']) {
      for (const layout of ['standalone', 'bundle', 'split']) {
        for (const minify of [false, true]) {
          test(`${name}, ${target}, ${layout}, minify=${minify}`, async () => {
            const module = `export async function run(){${body}}\n`;
            const standalone = module + bridge + finish + 'finish(run);\n';
            const fixture = await createFixture({
              'package.json': '{"type":"module"}',
              'input.mjs': standalone,
              'lazy.mjs': module,
              'entry.mjs': bridge + finish + 'import("./lazy.mjs").then(({run})=>finish(run));\n',
            });
            try {
              const reference = spawnSync('node', [join(fixture.dir, 'input.mjs')], {
                encoding: 'utf8',
              });
              expect(reference.status, reference.stderr).toBe(0);
              const output = join(fixture.dir, layout === 'split' ? 'dist/entry.js' : 'out.mjs');
              const args = [
                layout === 'standalone' ? 'input.mjs' : 'entry.mjs',
                `--target=${target}`,
              ];
              if (layout !== 'standalone') args.push('--bundle', '--platform=node', '--format=esm');
              if (layout === 'split') args.push('--splitting', '--outdir', 'dist');
              else args.push('-o', output);
              if (minify) args.push('--minify-syntax', '--minify-identifiers');
              const result = spawnSync(ZNTC_BIN, args, {
                cwd: fixture.dir,
                encoding: 'utf8',
                env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
              });
              expect(result.status, result.stderr).toBe(0);
              const helperReports = result.stderr
                .split(/\r?\n/)
                .filter(
                  (line) =>
                    line.startsWith('zntc: symbol-identity-prepass ') &&
                    /runtime\/(async-values|async-generator|yield-star):/.test(line),
                );
              if (layout !== 'standalone') {
                // Plain ES5 helper bodies can bypass transform prepass entirely.
                // Initial-analysis identity is checked directly in the Zig regression.
                if (minify) expect(helperReports.length, result.stderr).toBeGreaterThan(0);
                for (const report of helperReports) expect(report).toMatch(/clean=1(?:\s|$)/);
              }
              const actual = spawnSync('node', [output], { encoding: 'utf8' });
              expect(actual.status, actual.stderr).toBe(0);
              expect(actual.stdout).toBe(reference.stdout);
            } finally {
              await fixture.cleanup();
            }
          });
        }
      }
    }
  }
});
