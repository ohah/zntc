import {
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  transpile,
  tmpdir,
  writeFileSync,
} from '../../helpers';

describe('@zntc/core edge cases: transpile ES5 target', () => {
  test('derived fields keep distinct captures on both nested super paths', () => {
    const source = `
      const log = [];
      class Base {
        constructor(value) { log.push("base:" + value); this.value = value; }
      }
      class Child extends Base {
        a = log.push("a:" + this.value);
        b = log.push("b:" + this.value);
        constructor(flag) {
          log.push("before");
          if (flag) {
            const first = (log.push("branch"), super(7));
            log.push("after:" + (first === this));
          } else {
            super(9);
          }
        }
      }
      new Child(true);
      new Child(false);
      globalThis.__derivedResult = log;
    `;
    const expected = [
      'before',
      'branch',
      'base:7',
      'a:7',
      'b:7',
      'after:true',
      'before',
      'base:9',
      'a:9',
      'b:9',
    ];
    const vm = require('node:vm') as typeof import('node:vm');
    for (const minify of [false, true]) {
      const result = transpile(source, { target: 'es5', minify });
      const actual: { __derivedResult?: unknown } = {};
      vm.runInNewContext(result.code, actual);
      expect(JSON.stringify(actual.__derivedResult)).toBe(JSON.stringify(expected));
    }
  });

  test('derived fields run before the rest of a super declarator initializer', () => {
    const source = `
      const result = [];
      class Base { constructor(value) { this.value = value; } }
      class Child extends Base {
        field = this.value + 1;
        constructor(flag) {
          if (flag) {
            const first = (super(7), this.field), second = this.field;
            result.push(first, second);
          } else {
            const first = (super(9), this.field), second = this.field;
            result.push(first, second);
          }
        }
      }
      new Child(true);
      new Child(false);
      globalThis.__derivedResult = result;
    `;
    const vm = require('node:vm') as typeof import('node:vm');
    for (const minify of [false, true]) {
      const result = transpile(source, { target: 'es5', minify });
      const actual: { __derivedResult?: unknown } = {};
      vm.runInNewContext(result.code, actual);
      expect(JSON.stringify(actual.__derivedResult)).toBe('[8,8,10,10]');
    }
  });

  test('derived field captures survive expression shapes and nested function boundaries', () => {
    const source = `
      class Box { constructor(value) { this.value = value; } }
      class Base { constructor(value) { this.value = value; } }
      class Child extends Base {
        values = [this.value > 7 ? this["value"] : -this.value, { value: this.value }, new Box(this.value).value, !this.value];
        arrow = () => this.value;
        method = function () { return this.value; };
        constructor(flag) {
          if (flag) { const first = super(7); }
          else { super(9); }
        }
      }
      const first = new Child(true), second = new Child(false);
      globalThis.__derivedResult = [first.values, second.values, first.arrow(), second.arrow(), first.method.call({ value: 11 }), second.method.call({ value: 13 })];
    `;
    const vm = require('node:vm') as typeof import('node:vm');
    const expected: { __derivedResult?: unknown } = {};
    vm.runInNewContext(source, expected);
    for (const minify of [false, true]) {
      const result = transpile(source, { target: 'es5', minify });
      const actual: { __derivedResult?: unknown } = {};
      vm.runInNewContext(result.code, actual);
      expect(JSON.stringify(actual.__derivedResult)).toBe(JSON.stringify(expected.__derivedResult));
    }
  });

  test('derived fields retain outer reads alongside renamed constructor branch locals', () => {
    const source = `
      const label = "outer", log = [];
      class Base { constructor(value) { this.value = value; } }
      class Child extends Base {
        field = label + ":" + this.value;
        constructor(flag) {
          if (flag) { let label = "first"; super(7); log.push(label); }
          else { let label = "second"; super(9); log.push(label); }
          log.push(this.field, label);
        }
      }
      new Child(true);
      new Child(false);
      globalThis.__derivedResult = log;
    `;
    const vm = require('node:vm') as typeof import('node:vm');
    for (const minify of [false, true]) {
      const result = transpile(source, { target: 'es5', minify });
      const actual: { __derivedResult?: unknown } = {};
      vm.runInNewContext(result.code, actual);
      expect(JSON.stringify(actual.__derivedResult)).toBe(
        JSON.stringify(['first', 'outer:7', 'outer', 'second', 'outer:9', 'outer']),
      );
    }
  });

  test('build target es5 keeps optional chaining temp declarations in nested functions', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es5-optional-temp-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          function createProxy(state: any) {
            state.callbacks.push(function rootDraftCleanup(rootScope: any) {
              rootScope.mapSetPlugin_?.fixSetContents(state);
              const { patchPlugin_ } = rootScope;
              if (state.modified_ && patchPlugin_) {
                patchPlugin_.generatePatches_(state, [], rootScope);
              }
            });
          }

          const calls: string[] = [];
          const state = { callbacks: [] as Function[], modified_: true };
          createProxy(state);
          state.callbacks[0]({
            mapSetPlugin_: { fixSetContents() { calls.push("map"); } },
            patchPlugin_: { generatePatches_() { calls.push("patch"); } },
          });
          globalThis.__VALUE__ = calls.join(",");
        `,
      );

      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        target: 'es5',
      });
      expect(result.errors.length).toBe(0);
      const code = result.outputFiles[0].text;
      expect(code).not.toContain('?.');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(code, sandbox);
      expect(sandbox.__VALUE__).toBe('map,patch');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
