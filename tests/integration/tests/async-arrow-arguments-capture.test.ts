import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cases = [
  {
    name: 'captures the outer arguments object without shadowing a user _arguments',
    source: `
      function read(a, b, _arguments) {
        const outer = _arguments;
        return (async () => {
          const _arguments = 99;
          await Promise.resolve();
          return [arguments.length, arguments[0], _arguments, outer].join(':');
        })();
      }
      read(11, 22, 33).then(console.log);
    `,
    expected: '3:11:99:33\n',
    expectsSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'keeps the outer arguments binding through nested async arrows',
    source: `
      function read(a, b) {
        return (async () => {
          await Promise.resolve();
          return (async () => {
            await Promise.resolve();
            return arguments.length + ':' + arguments[0];
          })();
        })();
      }
      read(11, 22).then(console.log);
    `,
    expected: '2:11\n',
    expectsSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'captures an explicit arguments parameter by its source binding',
    inputFile: 'input.cjs',
    source: `
      function read(arguments) {
        return (async () => {
          await Promise.resolve();
          return arguments;
        })();
      }
      read(42).then(console.log);
    `,
    expected: '42\n',
    expectsSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'leaves arguments in async arrow parameter defaults in the lexical environment',
    source: `
      function read(a, b) {
        return (async (count = arguments.length) => {
          await Promise.resolve();
          return count;
        })();
      }
      read(11, 22).then(console.log);
    `,
    expected: '2\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: true,
  },
  {
    name: 'does not capture arguments owned by a nested ordinary function',
    target: 'es5',
    source: `
      function read() {
        return (async () => {
          await Promise.resolve();
          function nested(first, second) {
            return arguments.length + ':' + arguments[0];
          }
          return nested(21, 34);
        })();
      }
      read().then(console.log);
    `,
    expected: '2:21\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains lexical new.target through nested async arrows and collisions',
    source: `
      function read(_newTarget) {
        const outer = _newTarget;
        return (async () => {
          const _newTarget = 99;
          await Promise.resolve();
          return (async () => {
            await Promise.resolve();
            return [new.target === read, _newTarget, outer].join(':');
          })();
        })();
      }
      new read(7).then(console.log);
    `,
    expected: 'true:99:7\n',
    expectsSyntheticBinding: true,
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains lexical this capture identity through _this name collisions',
    source: `
      function read(_this) {
        const outer = _this;
        return (async () => {
          const _this = 99;
          await Promise.resolve();
          return [this.value, _this, outer].join(':');
        })();
      }
      read.call({ value: 42 }, 7).then(console.log);
    `,
    expected: '42:99:7\n',
    expectsSyntheticBinding: false,
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'shares lexical this capture through nested async arrows',
    source: `
      function read() {
        return (async () => {
          await Promise.resolve();
          return (async () => {
            await Promise.resolve();
            return this.value;
          })();
        })();
      }
      read.call({ value: 42 }).then(console.log);
    `,
    expected: '42\n',
    expectsSyntheticBinding: false,
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'lowers instance lexical super before the async body enters its generator',
    source: `
      class Base {
        read(suffix) { return this.prefix + suffix; }
      }
      class Child extends Base {
        readAsync(suffix, _a) {
          this.prefix = 'instance:';
          return (async () => {
            await Promise.resolve();
            return super.read(suffix);
          })();
        }
      }
      new Child().readAsync('instance', 42).then(console.log);
    `,
    expected: 'instance:instance\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains exact graph for ES5 async-arrow state machine with class lexical super',
    target: 'es5',
    source: `
      class Base {
        read(suffix) { return this.prefix + suffix; }
      }
      class Child extends Base {
        readAsync(suffix, _a) {
          this.prefix = 'instance:';
          return (async () => {
            await Promise.resolve();
            return super.read(suffix);
          })();
        }
      }
      new Child().readAsync('instance', 42).then(console.log);
    `,
    expected: 'instance:instance\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains exact graph for ES5 async-arrow state machine with static lexical super',
    target: 'es5',
    source: `
      class Base {
        static read(suffix) { return this.prefix + suffix; }
      }
      class Child extends Base {
        static readAsync(suffix, _a) {
          this.prefix = 'static:';
          return (async () => {
            await Promise.resolve();
            return super.read(suffix);
          })();
        }
      }
      Child.readAsync('static', 42).then(console.log);
    `,
    expected: 'static:static\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains exact graph for ES5 async-arrow state machine with object-method lexical super',
    target: 'es5',
    source: `
      var base = {
        read(suffix) { return this.prefix + suffix; }
      };
      var child = {
        __proto__: base,
        prefix: 'object:',
        readAsync(suffix, _a) {
          return (async () => {
            await Promise.resolve();
            return super.read(suffix);
          })();
        }
      };
      child.readAsync('ok', 42).then(console.log);
    `,
    expected: 'object:ok\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'reanalyzes ES5 object methods with direct and async-arrow super together',
    target: 'es5',
    source: `
      var base = {
        read(suffix) { return this.prefix + suffix; }
      };
      var child = {
        __proto__: base,
        prefix: 'object:',
        readAsync(suffix) {
          var direct = super.read('direct:');
          return (async () => {
            await Promise.resolve();
            return direct + ':' + super.read(suffix);
          })();
        }
      };
      child.readAsync('ok').then(console.log);
    `,
    expected: 'object:direct::object:ok\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: false,
  },
  {
    name: 'keeps computed-key ES5 object methods with async-arrow super on reanalysis',
    target: 'es5',
    source: `
      var base = {
        read(suffix) { return this.prefix + suffix; }
      };
      var methodKey = 'readAsync';
      var child = {
        __proto__: base,
        prefix: 'object:',
        [methodKey](suffix) {
          return (async () => {
            await Promise.resolve();
            return super.read(suffix);
          })();
        }
      };
      child.readAsync('ok').then(console.log);
    `,
    expected: 'object:ok\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: false,
  },
  {
    name: 'reanalyzes ES5 class methods with direct and async-arrow super together',
    target: 'es5',
    source: `
      class Base {
        read(suffix) { return this.prefix + suffix; }
      }
      class Child extends Base {
        readAsync(suffix) {
          this.prefix = 'instance:';
          var direct = super.read('direct:');
          return (async () => {
            await Promise.resolve();
            return direct + ':' + super.read(suffix);
          })();
        }
      }
      new Child().readAsync('instance').then(console.log);
    `,
    expected: 'instance:direct::instance:instance\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: false,
  },
  {
    name: 'retains ES5 async-arrow state machines with ordinary lexical bindings',
    target: 'es5',
    source: `
      function read(value) {
        return (async () => {
          await Promise.resolve();
          return value + 2;
        })();
      }
      read(40).then(console.log);
    `,
    expected: '42\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains ES5 class async arrows without home-object captures',
    target: 'es5',
    source: `
      class Child {
        readAsync(value) {
          return (async () => {
            await Promise.resolve();
            return value + 2;
          })();
        }
      }
      new Child().readAsync(40).then(console.log);
    `,
    expected: '42\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains ES5 async-arrow state machines with lexical arguments',
    target: 'es5',
    source: `
      function read(value) {
        return (async () => {
          await Promise.resolve();
          return arguments.length + ':' + arguments[0] + ':' + value;
        })();
      }
      read(40).then(console.log);
    `,
    expected: '1:40:40\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains ES5 async-arrow arguments through source-name collisions',
    target: 'es5',
    source: `
      function read(a, b, _arguments) {
        var outer = _arguments;
        return (async () => {
          var _arguments = 99;
          await Promise.resolve();
          return [arguments.length, arguments[0], _arguments, outer].join(':');
        })();
      }
      read(11, 22, 33).then(console.log);
    `,
    expected: '3:11:99:33\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains nested ES5 async-arrow state machines with outer arguments',
    target: 'es5',
    source: `
      function read(a, b) {
        return (async () => {
          await Promise.resolve();
          return (async () => {
            await Promise.resolve();
            return arguments.length + ':' + arguments[0];
          })();
        })();
      }
      read(11, 22).then(console.log);
    `,
    expected: '2:11\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains ES5 async-arrow state machines with lexical this',
    target: 'es5',
    source: `
      function read(value) {
        return (async () => {
          await Promise.resolve();
          return this.prefix + value;
        })();
      }
      read.call({ prefix: 'value:' }, 42).then(console.log);
    `,
    expected: 'value:42\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains ES5 async-arrow lexical this through source-name collisions',
    target: 'es5',
    source: `
      function read(_this, value) {
        return (async () => {
          var local = _this;
          await Promise.resolve();
          return [this.prefix, local].join(':');
        })();
      }
      read.call({ prefix: 'value:' }, 'source:_this', 42).then(console.log);
    `,
    expected: 'value::source:_this\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains nested ES5 async-arrow state machines with lexical this',
    target: 'es5',
    source: `
      function read(value) {
        return (async () => {
          await Promise.resolve();
          return (async () => {
            await Promise.resolve();
            return this.prefix + value;
          })();
        })();
      }
      read.call({ prefix: 'value:' }, 42).then(console.log);
    `,
    expected: 'value:42\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains ES5 async-arrow state machines with lexical new.target',
    target: 'es5',
    source: `
      function read(_newTarget) {
        var outer = _newTarget;
        return (async () => {
          var _newTarget = 99;
          await Promise.resolve();
          return (async () => {
            await Promise.resolve();
            return [new.target === read, _newTarget, outer].join(':');
          })();
        })();
      }
      new read(7).then(console.log);
    `,
    expected: 'true:99:7\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'keeps ES5 async-arrow state machines with direct eval on reanalysis',
    target: 'es5',
    source: `
      function read(value) {
        return (async () => {
          await Promise.resolve();
          return eval('value');
        })();
      }
      read(42).then(console.log);
    `,
    expected: '42\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: false,
    expectsCleanIdentity: false,
  },
  {
    name: 'retains ES5 object-method async-arrow super with lexical new.target',
    target: 'es5',
    source: `
      var proto = { read() { return 'base'; } };
      var child = {
        __proto__: proto,
        readAsync(_newTarget) {
          var outer = _newTarget;
          return (async () => {
            var _newTarget = 99;
            await Promise.resolve();
            return super.read() + ':' + String(new.target) + ':' + _newTarget + ':' + outer;
          })();
        },
      };
      child.readAsync('source:_newTarget').then(console.log);
    `,
    expected: 'base:undefined:99:source:_newTarget\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains ES5 class-method async-arrow super with lexical new.target',
    target: 'es5',
    source: `
      class Base { read() { return this.prefix; } }
      class Child extends Base {
        readAsync(_newTarget) {
          this.prefix = 'class:';
          var outer = _newTarget;
          return (async () => {
            var _newTarget = 99;
            await Promise.resolve();
            return super.read() + ':' + String(new.target) + ':' + _newTarget + ':' + outer;
          })();
        }
      }
      new Child().readAsync('source:_newTarget').then(console.log);
    `,
    expected: 'class::undefined:99:source:_newTarget\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains ES5 async-arrow super with lexical this and arguments',
    target: 'es5',
    source: `
      class Base {
        read(value) { return this.prefix + value; }
      }
      class Child extends Base {
        readAsync(_this, _arguments, value) {
          this.prefix = 'value:';
          var outer = _this;
          var outerArguments = _arguments;
          return (async () => {
            var _this = 99;
            var _arguments = 88;
            await Promise.resolve();
            return super.read(arguments[2]) + this.prefix + ':' + _this + ':' + outer + ':' + _arguments + ':' + outerArguments;
          })();
        }
      }
      new Child().readAsync('source:this', 'source:arguments', 42).then(console.log);
    `,
    expected: 'value:42value::99:source:this:88:source:arguments\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains ES5 async-arrow super with lexical arguments',
    target: 'es5',
    source: `
      class Base {
        read(value) { return this.prefix + value; }
      }
      class Child extends Base {
        readAsync(_arguments) {
          this.prefix = 'value:';
          var outer = _arguments;
          return (async () => {
            var _arguments = 99;
            await Promise.resolve();
            return super.read(arguments[0]) + ':' + _arguments + ':' + outer;
          })();
        }
      }
      new Child().readAsync('source:_arguments').then(console.log);
    `,
    expected: 'value:source:_arguments:99:source:_arguments\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains ES5 object-method async-arrow super with lexical arguments',
    target: 'es5',
    source: `
      var proto = { read(value) { return this.prefix + value; } };
      var child = {
        __proto__: proto,
        readAsync(_arguments) {
          this.prefix = 'object:';
          var outer = _arguments;
          return (async () => {
            var _arguments = 99;
            await Promise.resolve();
            return super.read(arguments[0]) + ':' + _arguments + ':' + outer;
          })();
        },
      };
      child.readAsync('object:_arguments').then(console.log);
    `,
    expected: 'object:object:_arguments:99:object:_arguments\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains ES5 object-method async-arrow super with lexical this',
    target: 'es5',
    source: `
      var base = { read(value) { return this.prefix + value; } };
      var child = {
        __proto__: base,
        prefix: 'object:',
        readAsync(_this, value) {
          var outer = _this;
          return (async () => {
            var _this = 99;
            await Promise.resolve();
            return super.read(value) + this.prefix + ':' + _this + ':' + outer;
          })();
        },
      };
      child.readAsync('source:_this', 42).then(console.log);
    `,
    expected: 'object:42object::99:source:_this\n',
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'lowers static lexical super through the constructor base',
    source: `
      class Base {
        static read(suffix) { return this.prefix + suffix; }
      }
      class Child extends Base {
        static readAsync(suffix, _a) {
          this.prefix = 'static:';
          return (async () => {
            await Promise.resolve();
            return super.read(suffix);
          })();
        }
      }
      Child.readAsync('static', 42).then(console.log);
    `,
    expected: 'static:static\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: true,
  },
  {
    name: 'keeps an instance-field super base out of an enclosing static method',
    source: `
      class Base {
        read() { return this.prefix; }
      }
      class Outer {
        static build() {
          class Inner extends Base {
            constructor() {
              super();
              this.prefix = 'inner:';
            }
            value = (async () => {
              await Promise.resolve();
              return super.read();
            })();
          }
          return new Inner().value;
        }
      }
      Outer.build().then(console.log);
    `,
    expected: 'inner:\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: false,
  },
  {
    name: 'lowers object-method lexical super through its home object',
    source: `
      const Base = { read(suffix) { return this.prefix + suffix; } };
      const Child = {
        __proto__: Base,
        readAsync(suffix, _a) {
          const _obj = 'object:';
          this.prefix = _obj;
          return (async () => {
            await Promise.resolve();
            return super.read(suffix);
          })();
        },
      };
      Child.readAsync('object', 42).then(console.log);
    `,
    expected: 'object:object\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: true,
  },
  {
    name: 'keeps direct eval on the conservative graph path',
    source: `
      function read() {
        return (async () => {
          await Promise.resolve();
          return eval('40 + 2');
        })();
      }
      read().then(console.log);
    `,
    expected: '42\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: false,
    expectsCleanIdentity: false,
  },
] as const;

describe('async arrow arguments capture (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const bundle of [false, true]) {
    for (const minifyIdentifiers of [false, true]) {
      for (const scenario of cases) {
        test(`${scenario.name}, ${bundle ? 'bundle' : 'single'}, ${minifyIdentifiers ? 'identifier-minified' : 'plain'}`, async () => {
          const inputFile = scenario.inputFile ?? 'input.js';
          const fixture = await createFixture({
            [inputFile]: scenario.source,
            'package.json': '{"type":"commonjs"}',
          });
          cleanup = fixture.cleanup;

          const input = join(fixture.dir, inputFile);
          const native = spawnSync('node', [input], { encoding: 'utf8' });
          expect(native.status, native.stderr).toBe(0);
          expect(native.stdout).toBe(scenario.expected);

          const output = join(fixture.dir, bundle ? 'out.cjs' : 'out.js');
          const result = spawnSync(
            ZNTC_BIN,
            [
              ...(bundle ? ['--bundle', input, '--platform=node', '--format=cjs'] : [input]),
              `--target=${scenario.target ?? 'es2015'}`,
              ...(minifyIdentifiers ? ['--minify-identifiers'] : []),
              '-o',
              output,
            ],
            {
              cwd: fixture.dir,
              env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
              encoding: 'utf8',
            },
          );
          expect(result.status, result.stderr).toBe(0);

          if (bundle) {
            const mode = (result.stderr ?? '')
              .split(/\r?\n/)
              .find(
                (line) =>
                  line.startsWith('zntc: symbol-identity-prepass-mode ') &&
                  line.includes(inputFile),
              );
            expect(mode, result.stderr).toBeDefined();
            expect(mode).toContain(
              scenario.expectsRetainedGraph
                ? 'semantic_graph=retained'
                : 'semantic_graph=reanalyzed',
            );
          }

          const auditPrefix = bundle ? 'zntc: symbol-identity-prepass ' : 'zntc: symbol-identity ';
          const report = (result.stderr ?? '')
            .split(/\r?\n/)
            .find((line) => line.startsWith(auditPrefix) && line.includes(inputFile));
          expect(report, result.stderr).toBeDefined();
          if (scenario.expectsSyntheticBinding)
            expect(report).toMatch(/generated_bindings=[1-9]\d*/);
          if (bundle && scenario.expectsBundleSyntheticBinding)
            expect(report).toMatch(/generated_bindings=[1-9]\d*/);
          expect(report).toMatch(/generated_references=[1-9]\d*/);
          if (scenario.expectsCleanIdentity !== false) {
            expect(report).toMatch(/missing_binding=0/);
            expect(report).toMatch(/missing_reference=0/);
            expect(report).toMatch(/unclassified_reference=0/);
            expect(report).toMatch(/clean=1(?:\s|$)/);
          }

          const runtime = spawnSync('node', [output], { encoding: 'utf8' });
          expect(runtime.status, runtime.stderr).toBe(0);
          expect(runtime.stdout).toBe(native.stdout);
        });
      }
    }
  }
});
