import { describe, it, after } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const native = require(
  join(dirname(fileURLToPath(import.meta.url)), '../../zig-out/lib/zntc.node'),
);
const directory = mkdtempSync(join(tmpdir(), 'zntc-static-capture-napi-'));
after(() => rmSync(directory, { recursive: true, force: true }));
const cases = [
  [
    'strict-arguments-poison',
    'class Box{static read=function(){try{return typeof eval("arguments").callee;}catch(error){return error.name;}};}console.log(Box.read());',
  ],
  [
    'strict-ordinary-this',
    'class Box{static read=function(){return eval("this")};}const read=Box.read;console.log(read()===undefined);',
  ],
  [
    'strict-ordinary-var',
    'class Box{static read=function(){eval("var local=7");return typeof local;};}console.log(Box.read());',
  ],
  [
    'strict-legacy-number',
    'class Box{static read=()=>{try{return eval("010");}catch(error){return error.name;}};}console.log(Box.read());',
  ],
  [
    'bound-builtin-eval',
    'function run(eval){class Box{static read=()=>eval("this");}console.log(Box.read()===Box);}run(globalThis.eval);',
  ],
  ['literal-this', 'class Box { static value=7; static read=()=>eval("this.value"); }'],
  ['opaque-eval', 'class Box { static read=source=>eval(source); }'],
  ['ordinary-class-self', 'class Box { static read=function(){return eval("Box");}; }'],
  ['ordinary-opaque', 'class Box { static read=function(source){return eval(source);}; }'],
  ['readonly-eval', 'class Box { static read=function(){return eval("Box=1");}; }'],
];

describe('static initializer dynamic environment API diagnostics (#4819)', () => {
  for (const [name, source] of cases) {
    for (const target of ['es5', 'es2015', 'es2017']) {
      for (const mode of [{}, { minifyIdentifiers: true }, { minify: true }]) {
        const label = JSON.stringify(mode);
        it(`${name}: ${target} ${label} standalone throws an identifiable error`, () => {
          assert.throws(
            () => native.transpile(source, 'input.cjs', JSON.stringify({ target, ...mode })),
            /ZNTC1505/,
          );
        });
        it(`${name}: ${target} ${label} bundler returns an error diagnostic`, () => {
          const entry = join(directory, `${name}-${target}.cjs`);
          writeFileSync(entry, source);
          const result = native.buildSync({
            entryPoints: [entry],
            target,
            platform: 'node',
            ...mode,
          });
          assert.ok(
            result.errors.some((error) => error.code === 'static_initializer_dynamic_scope'),
            JSON.stringify(result.errors),
          );
        });
      }
    }
    it(`${name}: native static initializers remain supported in every mode`, () => {
      for (const mode of [{}, { minifyIdentifiers: true }, { minify: true }]) {
        assert.doesNotThrow(() =>
          native.transpile(source, 'input.cjs', JSON.stringify({ target: 'es2022', ...mode })),
        );
        const entry = join(directory, `${name}-native.cjs`);
        writeFileSync(entry, source);
        assert.equal(
          native.buildSync({ entryPoints: [entry], target: 'es2022', platform: 'node', ...mode })
            .errors.length,
          0,
        );
      }
    });
  }
  for (const [index, source] of [
    'class Box { static read=()=>eval("1+2"); }',
    'function run(evaluate){class Box{static read=()=>evaluate("this");}return Box;}run(globalThis.eval);',
    'function run(eval){class Box{static read=()=>eval("1+2");}return Box;}run(globalThis.eval);',
    'class Box { static read=function(){const local=7;return eval("local");}; }',
  ].entries()) {
    it('safe literal and indirect eval controls stay supported in both APIs', () => {
      const entry = join(directory, `safe-${index}.cjs`);
      writeFileSync(entry, source);
      for (const target of ['es5', 'es2015', 'es2017', 'es2022']) {
        for (const mode of [{}, { minifyIdentifiers: true }, { minify: true }]) {
          assert.doesNotThrow(() =>
            native.transpile(source, 'input.cjs', JSON.stringify({ target, ...mode })),
          );
          assert.equal(
            native.buildSync({ entryPoints: [entry], target, platform: 'node', ...mode }).errors
              .length,
            0,
          );
        }
      }
    });
  }
  it('ESM prepass returns structured bundle errors in every mode', () => {
    const entry = join(directory, 'structured.mjs');
    writeFileSync(entry, 'class Box{static read=()=>eval("this");}console.log(Box.read());');
    for (const mode of [{}, { minifyIdentifiers: true }, { minify: true }]) {
      const result = native.buildSync({
        entryPoints: [entry],
        target: 'es2015',
        platform: 'node',
        ...mode,
      });
      assert.ok(
        result.errors.some((error) => error.code === 'static_initializer_dynamic_scope'),
        JSON.stringify(result.errors),
      );
    }
  });
  it('asynchronous build preserves the prepass typed failure', async () => {
    const entry = join(directory, 'async-bound-eval.cjs');
    writeFileSync(
      entry,
      'function run(eval){class Box{static read=()=>eval("this");}console.log(Box.read()===Box);}run(globalThis.eval);',
    );
    const result = await native.build({ entryPoints: [entry], target: 'es2015', platform: 'node' });
    assert.ok(
      result.errors.some((error) => error.code === 'static_initializer_dynamic_scope'),
      JSON.stringify(result.errors),
    );
  });
  it('assign semantics rejects moved initializers even with a native target', () => {
    assert.throws(
      () =>
        native.transpile(
          cases[0][1],
          'input.cjs',
          JSON.stringify({ target: 'es2022', useDefineForClassFields: false }),
        ),
      /ZNTC1505/,
    );
  });
});
