import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, runZntcInDir, ZNTC_BIN } from './helpers';

// These cases use distinct source SymbolIds for parameters/outer names and
// body bindings. Splitting a parameter and a body var represented by one SID,
// and dynamic eval/with parameter environments, require a separate scope model.
const cases = [
  {
    name: 'computed key reads outer binding before body var exists',
    source: `var x = 'outer';
      function f({ [x]: value }) { var x = 'inner'; return [value, x]; }
      console.log(JSON.stringify(f({ outer: 3, inner: 4 })));`,
    expected: '[3,"inner"]\n',
  },
  {
    name: 'computed key writes outer binding',
    source: `var x = 'before';
      function f({ [x = 'outer']: value }) { var x = 'inner'; return [value, x]; }
      console.log(JSON.stringify([f({ outer: 3 }), x]));`,
    expected: '[[3,"inner"],"outer"]\n',
  },
  {
    name: 'computed key calls nested function reading outer binding',
    source: `var x = 'outer';
      function f({ [(function () { return x; })()]: value }) {
        var x = 'inner'; return [value, x];
      }
      console.log(JSON.stringify(f({ outer: 3 })));`,
    expected: '[3,"inner"]\n',
  },
  {
    name: 'computed key saves an arrow that outlives body mutation',
    source: `var x = 'outer', saved;
      function f({ [(saved = () => x, x)]: value }) {
        var x = 'inner'; x += '!'; return [value, x];
      }
      console.log(JSON.stringify([f({ outer: 3 }), saved()]));`,
    expected: '[[3,"inner!"],"outer"]\n',
  },
  {
    name: 'computed key saves a function that outlives body mutation',
    source: `var x = 'outer', saved;
      function f({ [(saved = function () { return x; }, x)]: value }) {
        var x = 'inner'; return [value, x];
      }
      console.log(JSON.stringify([f({ outer: 3 }), saved()]));`,
    expected: '[[3,"inner"],"outer"]\n',
  },
  {
    name: 'conditionally declared body var is hoisted',
    source: `var x = 'outer';
      function f({ [x]: value }, enabled) { if (enabled) { var x = 'inner'; } return [value, x]; }
      console.log(JSON.stringify(f({ outer: 3 }, false)));`,
    expected: '[3,null]\n',
  },
  {
    name: 'unresolved builtin is not intercepted by body var',
    source: `function f({ [Object.keys({ a: 1 })[0]]: value }) {
        var Object = 9; return [value, Object];
      }
      console.log(JSON.stringify(f({ a: 3 })));`,
    expected: '[3,9]\n',
  },
  {
    name: 'body shorthand retains its property key and labels retain spelling',
    source: `var x = 'outer';
      function f({ [x]: value }) {
        var x = 'inner'; x: { if (value) break x; x = 'wrong'; }
        return { x, value };
      }
      console.log(JSON.stringify(f({ outer: 3 })));`,
    expected: '{"x":"inner","value":3}\n',
  },
  {
    name: 'fresh body spelling cannot capture an existing dollar name',
    targets: ['es5'],
    source: `var x = 'outer', x$1 = 11, x$2 = 12;
      function f({ [x]: value }) { var x = 'inner'; return [value, x, x$1, x$2]; }
      console.log(JSON.stringify(f({ outer: 3 })));`,
    expected: '[3,"inner",11,12]\n',
  },
  {
    name: 'inner function local binding is not an outer parameter reference',
    source: `function f({ [(function (x) { return x; })('outer')]: value }) {
        var x = 'inner'; return [value, x];
      }
      console.log(JSON.stringify(f({ outer: 3 })));`,
    expected: '[3,"inner"]\n',
  },
  {
    name: 'default expression precedes body var environment',
    source: `var x = 3;
      function f(value = x) { var x = 4; return [value, x]; }
      console.log(JSON.stringify([f(), f(7)]));`,
    expected: '[[3,4],[7,4]]\n',
  },
  {
    name: 'parameter closure keeps its value apart from a same-named body var',
    source: `function f(x = 3, get = () => x) { var x = 4; return [get(), x]; }
      console.log(JSON.stringify(f()));`,
    expected: '[3,4]\n',
  },
  {
    name: 'parameter closure writes stay apart from body var initialization',
    source: `function f(x = 3, update = () => { x = 5; }, get = () => x) {
        var x = x || 4; update(); return [get(), x];
      }
      console.log(JSON.stringify(f()));`,
    expected: '[5,3]\n',
  },
  {
    name: 'destructured parameter closure keeps shorthand key and body var separate',
    source: `function f({ x }, get = () => x) { var x = 4; return [get(), x]; }
      console.log(JSON.stringify(f({ x: 3 })));`,
    expected: '[3,4]\n',
  },
  {
    name: 'fresh parameter environment name avoids source aliases',
    source: `var __zntc_param_env_0 = 9, __zntc_param_env_1 = 10;
      function f(x = 3, get = () => x) { var x = 4; return [get(), x, __zntc_param_env_0, __zntc_param_env_1]; }
      console.log(JSON.stringify(f()));`,
    expected: '[3,4,9,10]\n',
  },
  {
    name: 'object parameter initialization does not overwrite body function',
    keepNames: true,
    source: `function f({ x }) { function x() { return 8; } return [x(), x.name]; }
      console.log(JSON.stringify(f({ x: 3 })));`,
    expected: '[8,"x"]\n',
  },
  {
    name: 'array parameter initialization does not overwrite body function',
    source: `function f([x]) { function x() { return 8; } return x(); }
      console.log(f([3]));`,
    expected: '8\n',
  },
  {
    name: 'parameter getters still execute before body function call',
    source: `var events = [];
      function f({ x }, read = () => x) {
        function x() { events.push('body'); return 8; } return [read(), x()];
      }
      var result = f({ get x() { events.push('parameter'); return 3; } });
      console.log(JSON.stringify([result, events]));`,
    expected: '[[3,8],["parameter","body"]]\n',
  },
  {
    name: 'default and parameter closure keep value before body function initialization',
    source: `function f(x = 3, get = () => x) {
        function x() { return 8; } return [get(), x()];
      }
      console.log(JSON.stringify([f(), f(7)]));`,
    expected: '[[3,8],[7,8]]\n',
  },
  {
    name: 'rest parameter does not overwrite body function',
    source: `function f(...x) { function x() { return 8; } return x(); }
      console.log(f(1, 2, 3));`,
    expected: '8\n',
  },
  {
    name: 'method retains this and arguments while separating body var',
    source: `var x = 'outer';
      var object = { base: 7, f({ [x]: value }) {
        var x = 'inner'; return [value, x, this.base, arguments.length];
      } };
      console.log(JSON.stringify(object.f({ outer: 3 })));`,
    expected: '[3,"inner",7,1]\n',
  },
  {
    name: 'constructor retains new target while separating body var',
    source: `var x = 'outer';
      function F({ [x]: value }) {
        var x = 'inner'; this.result = [value, x, new.target === F, arguments.length];
      }
      console.log(JSON.stringify(new F({ outer: 3 }).result));`,
    expected: '[3,"inner",true,1]\n',
  },
  {
    name: 'simple parameter var redeclaration retains shared storage',
    source: `function f({ x }) { var x = 4; return x; }
      console.log(f({ x: 3 }));`,
    expected: '4\n',
  },
  {
    name: 'later parameter remains in TDZ before body function initialization',
    source: `function f(value = x, x = 3) { function x() { return 8; } return [value, x()]; }
      try { console.log(JSON.stringify(f())); } catch (error) { console.log(error.name); }`,
    expected: 'ReferenceError\n',
  },
  {
    name: 'self-referencing parameter remains in TDZ before body function initialization',
    source: `function f(x = x) { function x() { return 8; } return x(); }
      try { console.log(f()); } catch (error) { console.log(error.name); }`,
    expected: 'ReferenceError\n',
  },
  {
    name: 'renamed body var retains inferred function name and outer recursive reference',
    targets: ['es5'],
    source: `var x = 3;
      function f(value = x) {
        var x = function () { return x; }, saved = x;
        var name = x.name; x = 9; return [value, name, saved()];
      }
      console.log(JSON.stringify(f(7)));`,
    expected: '[7,"x",9]\n',
  },
  {
    name: 'renamed body assignment retains inferred arrow name',
    targets: ['es5'],
    source: `var x = 3;
      function f(value = x) { var x; x = () => value; return [x(), x.name]; }
      console.log(JSON.stringify(f(7)));`,
    expected: '[7,"x"]\n',
  },
  {
    name: 'renamed parameter retains inferred default function name',
    targets: ['es5'],
    source: `function f(x = function () {}, get = () => x.name) {
        function x() {} return get();
      }
      console.log(f());`,
    expected: 'x\n',
  },
  {
    name: 'renamed parameter retains inferred proto name without a lexical self binding',
    targets: ['es5'],
    source: `function f(__proto__ = () => 3, get = () => __proto__.name) {
        function __proto__() {} return get();
      }
      console.log(f());`,
    expected: '__proto__\n',
  },
  {
    name: 'renamed logical assignment retains inferred function name',
    targets: ['es5'],
    source: `var x = 3;
      function f(value = x) { var x; x ||= function () {}; return [value, x.name]; }
      console.log(JSON.stringify(f(7)));`,
    expected: '[7,"x"]\n',
  },
  {
    name: 'name helper is isolated from module and body Object bindings',
    targets: ['es5'],
    source: `var Object = 11, x = 3;
      function f(value = x) { var Object = 12, x = function () {}; return [value, x.name, Object]; }
      console.log(JSON.stringify([f(7), Object]));`,
    expected: '[[7,"x",12],11]\n',
  },
  {
    name: 'name helper cannot overwrite same-named user bindings',
    targets: ['es5'],
    source: `var __name = 11, $nm = 12, x = 3;
      function f(value = x) { var x = function () {}; return [value, x.name, __name, $nm]; }
      console.log(JSON.stringify(f(7)));`,
    expected: '[7,"x",11,12]\n',
  },
  {
    name: 'escaped identifier uses the decoded inferred name',
    targets: ['es5'],
    source: String.raw`var \u0078 = 3;
      function f(value = \u0078) { var \u0078 = function () {}; return [value, \u0078.name]; }
      console.log(JSON.stringify(f(7)));`,
    expected: '[7,"x"]\n',
  },
  {
    name: 'lowered anonymous class retains its inferred name',
    targets: ['es5'],
    source: `var x = 3;
      function f(value = x) { var x = class {}; return [value, x.name]; }
      console.log(JSON.stringify(f(7)));`,
    expected: '[7,"x"]\n',
  },
  {
    name: 'name helper captures the intrinsic before the module body mutates its prototype',
    targets: ['es5'],
    source: `var x = 3, builtinConstructor = ({}).constructor;
      function f(value = x) { var x = function () {}; return [value, x.name]; }
      try {
        builtinConstructor.prototype.constructor = 0;
        console.log(JSON.stringify(f(7)));
      } finally { builtinConstructor.prototype.constructor = builtinConstructor; }`,
    expected: '[7,"x"]\n',
  },
  {
    name: 'body direct eval still sees the original var name',
    source: `function f({ value }) { var x = 'inner'; return [value, eval('x')]; }
      console.log(JSON.stringify(f({ value: 3 })));`,
    expected: '[3,"inner"]\n',
  },
  {
    name: 'default reads outer binding before body function initialization',
    keepNames: true,
    source: `var x = 3;
      function f(value = x) { function x() { return 8; } return [value, x.name, x()]; }
      console.log(JSON.stringify(f()));`,
    expected: '[3,"x",8]\n',
  },
  {
    name: 'computed key reads outer binding before body function initialization',
    keepNames: true,
    source: `var x = 'outer';
      function f({ [x]: value }) { function x() { return 8; } return [value, x.name, x()]; }
      console.log(JSON.stringify(f({ outer: 3 })));`,
    expected: '[3,"x",8]\n',
  },
  {
    name: 'duplicate body functions retain the last declaration and its source name',
    keepNames: true,
    source: `var x = 3;
      function f(value = x) {
        function x() { return 1; } function x() { return 2; }
        return [value, x.name, x()];
      }
      console.log(JSON.stringify(f()));`,
    expected: '[3,"x",2]\n',
  },
  {
    name: 'closure between duplicate body functions reads the final declaration',
    source: `var x = 3;
      function f(value = x) {
        function x() { return 1; } function get() { return x; } function x() { return 2; }
        return [value, get()(), x()];
      }
      console.log(JSON.stringify(f()));`,
    expected: '[3,2,2]\n',
  },
  {
    name: 'body function name is restored before an early return preceding its declaration',
    keepNames: true,
    source: `var x = 3;
      function f(value = x) { return [value, x.name, x()]; function x() { return 8; } }
      console.log(JSON.stringify(f()));`,
    expected: '[3,"x",8]\n',
  },
  {
    name: 'escaped source alias cannot capture a literal dollar name',
    targets: ['es5'],
    source: String.raw`var \u0078 = 3, x$1 = 11;
      function f(value = \u0078) { var \u0078 = 'inner'; return [value, \u0078, x$1]; }
      console.log(JSON.stringify(f(7)));`,
    expected: '[7,"inner",11]\n',
  },
  {
    name: 'literal source alias cannot capture an escaped dollar name',
    targets: ['es5'],
    source: String.raw`var x = 3, \u0078$1 = 11;
      function f(value = x) { var x = 'inner'; return [value, x, \u0078$1]; }
      console.log(JSON.stringify(f(7)));`,
    expected: '[7,"inner",11]\n',
  },
  {
    name: 'astral escaped source alias cannot capture its UTF-8 dollar name',
    targets: ['es5'],
    source: String.raw`var \u{10400} = 3, 𐐀$1 = 11;
      function f(value = \u{10400}) { var \u{10400} = 'inner'; return [value, \u{10400}, 𐐀$1]; }
      console.log(JSON.stringify(f(7)));`,
    expected: '[7,"inner",11]\n',
  },
  ...['(function () {}) as any', '(function () {}) satisfies Function', '(function () {})!'].map(
    (expression) => ({
      name: `transparent type wrapper retains the inferred name: ${expression}`,
      targets: ['es5'],
      extension: 'ts',
      source: `var x = 3;
        function f(value = x) { var x = ${expression}; return [value, x.name]; }
        console.log(JSON.stringify(f(7)));`,
      expected: '[7,"x"]\n',
    }),
  ),
  {
    name: 'async body function keeps its restored name through lowering',
    targets: ['es5'],
    keepNames: true,
    source: `var x = 3;
      function f(value = x) {
        async function x() { return 8; }
        return x().then(result => [value, x.name, result]);
      }
      f().then(result => console.log(JSON.stringify(result)));`,
    expected: '[3,"x",8]\n',
  },
  {
    name: 'generator body function keeps its restored name through lowering',
    targets: ['es5'],
    keepNames: true,
    source: `var x = 3;
      function f(value = x) { function* x() { yield 8; } return [value, x.name, x().next().value]; }
      console.log(JSON.stringify(f()));`,
    expected: '[3,"x",8]\n',
  },
  ...['let', 'const'].map((kind) => ({
    name: `default reads outer binding before body ${kind} exists`,
    source: `var x = 3;
      function f(value = x) { ${kind} x = 4; return [value, x]; }
      console.log(JSON.stringify(f()));`,
    expected: '[3,4]\n',
  })),
  {
    name: 'long class name survives an outer alias and preserves self references',
    // Native-default identifier mangling is a separate existing limitation;
    // this fixture exercises the ES5 class storage split changed here.
    targets: ['es5'],
    keepNames: true,
    source: `var ShadowName = 3;
      function f(value = ShadowName) {
        class ShadowName {
          static initialName = this.name;
          static self() { return ShadowName; }
          self() { return ShadowName; }
        }
        var saved = ShadowName; ShadowName = null;
        return [value, saved.name, saved.initialName, saved.self() === saved, new saved().self() === saved];
      }
      console.log(JSON.stringify(f()));`,
    expected: '[3,"ShadowName","ShadowName",true,true]\n',
  },
  {
    name: 'body class restores its name before static initialization and retains its self binding',
    keepNames: true,
    source: `var x = 3;
      function f(value = x) {
        class x { static initialName = this.name; static self() { return x; } }
        var saved = x; x = null;
        return [value, saved.name, saved.initialName, saved.self() === saved];
      }
      console.log(JSON.stringify(f()));`,
    expected: '[3,"x","x",true]\n',
  },
  {
    name: 'escaping parameter closure stays outside a body lexical binding',
    source: `var x = 3;
      function f(read = () => x) { let x = 4; return [read, x]; }
      var result = f(); x = 5;
      console.log(JSON.stringify([result[0](), result[1]]));`,
    expected: '[5,4]\n',
  },
  {
    name: 'nested block lexical bindings remain separate from outer parameter reads',
    source: `var x = 3;
      function f(value = x) { var inner; { let x = 4; inner = x; } return [value, x, inner]; }
      console.log(JSON.stringify(f()));`,
    expected: '[3,3,4]\n',
  },
  {
    name: 'computed key writes outer binding before body let exists',
    source: `var x = 'before';
      function f({ [x = 'outer']: value }) { let x = 'inner'; return [value, x]; }
      console.log(JSON.stringify([f({ outer: 3 }), x]));`,
    expected: '[[3,"inner"],"outer"]\n',
  },
  {
    name: 'class heritage reads renamed body constructor for declarations and expressions',
    source: `var x = 3;
      function f(value = x) {
        var x = function Base() {};
        class Y extends x {}
        var Z = class extends x {};
        return [value, new Y() instanceof x, new Z() instanceof x];
      }
      console.log(JSON.stringify([f(7), f()]));`,
    expected: '[[7,true,true],[3,true,true]]\n',
  },
  {
    name: 'anonymous class names initialize before static fields and respect later overrides',
    targets: ['es5'],
    keepNames: true,
    source: `var x = 3;
      function f(value = x) {
        var x = class { static before = this.name; static ['name'] = 'own'; static after = this.name; };
        return [value, x.before, x.name, x.after];
      }
      console.log(JSON.stringify(f(7)));`,
    expected: '[7,"x","own","own"]\n',
  },
  {
    name: 'typed anonymous class static block may replace the inferred name',
    targets: ['es5'],
    extension: 'ts',
    source: `var x = 3;
      function f(value = x) {
        var x = (class { static { Object.defineProperty(this, 'name', { value: 'custom', configurable: false }); } }) as any;
        return [value, x.name];
      }
      console.log(JSON.stringify(f(7)));`,
    expected: '[7,"custom"]\n',
  },
];

describe('parameter evaluation environment', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const target of fixture.targets ?? ['es5', 'es2020']) {
      for (const bundle of [false, true]) {
        for (const flags of [[], ['--minify-identifiers'], ['--minify']]) {
          test(`${fixture.name}, ${target}, ${bundle ? 'bundle' : 'single'}, ${flags[0] ?? 'plain'}`, async () => {
            const input = `input.${fixture.extension ?? 'mjs'}`;
            const dir = await createFixture({
              [input]: fixture.source,
              'package.json': '{"type":"module"}',
            });
            cleanup = dir.cleanup;
            const native = spawnSync('node', [join(dir.dir, input)], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            expect(native.stdout).toBe(fixture.expected);
            const output = join(dir.dir, bundle ? 'out.cjs' : 'out.mjs');
            const compiled = await runZntcInDir(dir.dir, [
              ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
              input,
              `--target=${target}`,
              ...(fixture.keepNames ? ['--keep-names'] : []),
              ...flags,
              '-o',
              output,
            ]);
            expect(compiled.exitCode, compiled.stderr).toBe(0);
            const actual = spawnSync('node', [output], { encoding: 'utf8' });
            expect(actual.status, actual.stderr).toBe(0);
            expect(actual.stdout).toBe(native.stdout);
          });
        }
      }
    }
  }

  const graphFixtures = new Set([
    'computed key reads outer binding before body var exists',
    'parameter closure keeps its value apart from a same-named body var',
    'parameter closure writes stay apart from body var initialization',
    'destructured parameter closure keeps shorthand key and body var separate',
    'fresh parameter environment name avoids source aliases',
    'object parameter initialization does not overwrite body function',
    'renamed body var retains inferred function name and outer recursive reference',
    'default reads outer binding before body function initialization',
    'default reads outer binding before body let exists',
    'body class restores its name before static initialization and retains its self binding',
    'long class name survives an outer alias and preserves self references',
    'computed key writes outer binding before body let exists',
    'class heritage reads renamed body constructor for declarations and expressions',
    'anonymous class names initialize before static fields and respect later overrides',
    'typed anonymous class static block may replace the inferred name',
  ]);
  for (const fixture of cases.filter(({ name }) => graphFixtures.has(name))) {
    for (const bundle of [false, true]) {
      test(`exact binding/reference graph: ${fixture.name}, ${bundle ? 'bundle' : 'single'}`, async () => {
        const input = `input.${fixture.extension ?? 'mjs'}`;
        const dir = await createFixture({ [input]: fixture.source });
        cleanup = dir.cleanup;
        const output = join(dir.dir, bundle ? 'out.cjs' : 'out.mjs');
        const result = spawnSync(
          ZNTC_BIN,
          [
            ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
            input,
            '--target=es5',
            '-o',
            output,
          ],
          {
            cwd: dir.dir,
            encoding: 'utf8',
            env: {
              ...process.env,
              ZNTC_DISABLE_TRANSPILE_FAST_PATH: '1',
              ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
              ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
            },
          },
        );
        expect(result.status, result.stderr).toBe(0);
        const reports = result.stderr
          .split(/\r?\n/)
          .filter((line) => /^zntc: symbol-identity(?:-prepass)? /.test(line));
        expect(reports.length, result.stderr).toBeGreaterThan(0);
        for (const report of reports) expect(report).toMatch(/clean=1(?:\s|$)/);
        if (!bundle) {
          const strict = result.stderr
            .split(/\r?\n/)
            .find((line) => line.startsWith('zntc: synthetic-coverage '));
          expect(strict, result.stderr).toBeDefined();
          expect(strict).toMatch(
            new RegExp(`\\bscope_mismatch=${fixture.legacyScopeMismatches ?? 0}(?:\\s|$)`),
          );
          expect(strict).toMatch(/\bconsistent=1(?:\s|$)/);
          expect(strict).toMatch(/\borphan_symbols=0(?:\s|$)/);
          expect(strict).toMatch(/\bsymbol_identity_complete=1(?:\s|$)/);
        }
      });
    }
  }

  for (const strict of [false, true]) {
    for (const flags of [[], ['--minify']]) {
      test(`standalone helper preserves hashbang and inherited ${strict ? 'strict' : 'sloppy'} mode, ${flags[0] ?? 'plain'}`, async () => {
        const source = `#!/usr/bin/env node\n'use custom';\n${strict ? "'use strict';" : ''}
          var x = 3;
          function f(value = x) { return [value, this === undefined, x.name]; function x() {} }
          console.log(JSON.stringify(f()));`;
        const dir = await createFixture({ 'input.cjs': source });
        cleanup = dir.cleanup;
        const native = spawnSync('node', [join(dir.dir, 'input.cjs')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        expect(native.stdout).toBe(`[3,${strict},"x"]\n`);
        const output = join(dir.dir, 'out.cjs');
        const result = await runZntcInDir(dir.dir, [
          'input.cjs',
          '--target=es5',
          ...flags,
          '-o',
          output,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        expect((await readFile(output, 'utf8')).startsWith('#!/usr/bin/env node\n')).toBe(true);
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(0);
        expect(actual.stdout).toBe(native.stdout);
      });
    }
  }

  for (const flags of [[], ['--minify']]) {
    test(`helper preamble preserves source-map lines, ${flags[0] ?? 'plain'}`, async () => {
      const source = `'use strict';\nvar x = 3;\nfunction f(value = x) { var x = function () {}; throw new Error(x.name + value); }\nf(7);\n`;
      const dir = await createFixture({ 'input.cjs': source });
      cleanup = dir.cleanup;
      const output = join(dir.dir, 'out.cjs');
      const result = await runZntcInDir(dir.dir, [
        'input.cjs',
        '--target=es5',
        '--sourcemap',
        ...flags,
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const actual = spawnSync('node', ['--enable-source-maps', output], { encoding: 'utf8' });
      expect(actual.status).toBe(1);
      expect(actual.stderr).toContain('Error: x7');
      expect(actual.stderr).toMatch(/input\.cjs:3:\d+/);
    });
  }

  test('duplicate function records do not become synthetic orphan bindings', async () => {
    const dir = await createFixture({ 'input.mjs': cases[34].source });
    cleanup = dir.cleanup;
    const result = spawnSync(ZNTC_BIN, ['input.mjs', '--target=es5'], {
      cwd: dir.dir,
      encoding: 'utf8',
      env: {
        ...process.env,
        ZNTC_DISABLE_TRANSPILE_FAST_PATH: '1',
        ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
        ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
      },
    });
    expect(result.status, result.stderr).toBe(0);
    const strict = result.stderr
      .split(/\r?\n/)
      .find((line) => line.startsWith('zntc: synthetic-coverage '));
    expect(strict, result.stderr).toBeDefined();
    expect(strict).toMatch(/\borphan_symbols=0(?:\s|$)/);
    expect(strict).toMatch(/\bsymbol_identity_complete=1(?:\s|$)/);
  });
});
