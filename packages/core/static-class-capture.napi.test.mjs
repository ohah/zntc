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
  ['literal-this', 'class Box { static value=7; static read=()=>eval("this.value"); }'],
  ['opaque-eval', 'class Box { static read=source=>eval(source); }'],
  ['ordinary-class-self', 'class Box { static read=function(){return eval("Box");}; }'],
  ['ordinary-opaque', 'class Box { static read=function(source){return eval(source);}; }'],
  ['readonly-eval', 'class Box { static read=function(){return eval("Box=1");}; }'],
];

describe('static initializer dynamic environment API diagnostics (#4819)', () => {
  for (const [name, source] of cases) {
    for (const target of ['es5', 'es2015', 'es2017']) {
      it(`${name}: ${target} standalone throws an identifiable error`, () => {
        assert.throws(
          () => native.transpile(source, 'input.js', JSON.stringify({ target })),
          /ZNTC1505/,
        );
      });
      it(`${name}: ${target} bundler returns an error diagnostic`, () => {
        const entry = join(directory, `${name}-${target}.js`);
        writeFileSync(entry, source);
        const result = native.buildSync({ entryPoints: [entry], target, platform: 'node' });
        assert.ok(
          result.errors.some((error) =>
            /static initializer/.test(error.text ?? error.message ?? ''),
          ),
          JSON.stringify(result.errors),
        );
      });
    }
    it(`${name}: native static initializers remain supported`, () => {
      assert.doesNotThrow(() =>
        native.transpile(source, 'input.js', JSON.stringify({ target: 'es2022' })),
      );
      const entry = join(directory, `${name}-native.js`);
      writeFileSync(entry, source);
      assert.equal(
        native.buildSync({ entryPoints: [entry], target: 'es2022', platform: 'node' }).errors
          .length,
        0,
      );
    });
  }
  for (const source of [
    'class Box { static read=()=>eval("1+2"); }',
    'class Box { static read=function(){return eval("this");}; }',
    'class Box { static read=function(){const local=7;return eval("local");}; }',
  ]) {
    it('safe literal and ordinary-function eval are still supported', () => {
      for (const target of ['es5', 'es2015', 'es2017', 'es2022'])
        assert.doesNotThrow(() => native.transpile(source, 'input.js', JSON.stringify({ target })));
    });
  }
  it('assign semantics rejects moved initializers even with a native target', () => {
    assert.throws(
      () =>
        native.transpile(
          cases[0][1],
          'input.js',
          JSON.stringify({ target: 'es2022', useDefineForClassFields: false }),
        ),
      /ZNTC1505/,
    );
  });
});
