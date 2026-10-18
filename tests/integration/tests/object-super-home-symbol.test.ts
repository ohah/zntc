import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

describe('ES5 object-method home symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('standalone wrapper names are finalized from their exact parameter symbols', async () => {
    const fixture = await createFixture({
      'input.js': `var _obj = 10;
var _obj2 = 20;
var base = { read() { return this.input; } };
var methods = { read() { return super.read() + 1; } };
Object.setPrototypeOf(methods, base);
console.log(methods.read.call({ input: 41 }), _obj, _obj2);`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const native = spawnSync('node', [join(fixture.dir, 'input.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
    const transformed = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '-o', output], {
      cwd: fixture.dir,
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
      encoding: 'utf8',
    });
    expect(transformed.status, transformed.stderr).toBe(0);

    const report = transformed.stderr
      .split(/\r?\n/)
      .find((line) => line.startsWith('zntc: symbol-identity ') && line.includes('input.js'));
    expect(report, transformed.stderr).toMatch(/clean=1(?:\s|$)/);
    expect(report, transformed.stderr).toMatch(/missing_binding=0(?:\s|$)/);
    expect(report, transformed.stderr).toMatch(/missing_reference=0(?:\s|$)/);
    const code = readFileSync(output, 'utf8');
    expect(code).toMatch(/function\s*\(_obj3\)\s*\{/);
    expect(code).not.toContain('__zntc_object_home');

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
  });

  test('bundler finalizes object-super home parameters by SymbolId after semantic reanalysis', async () => {
    const fixture = await createFixture({
      'input.js': `var _obj = 'source-obj';
var _obj$1 = 'source-obj-1';
var _obj$2 = 'source-obj-2';
var base = { read() { return this.input; } };
var methods = { read() { return [super.read(), _obj, _obj$1, _obj$2].join(':'); } };
Object.setPrototypeOf(methods, base);
console.log(methods.read.call({ input: 'home' }), _obj, _obj$1, _obj$2);`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.cjs');
    const native = spawnSync('node', [join(fixture.dir, 'input.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
    const transformed = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        'input.js',
        '--target=es5',
        '--platform=node',
        '--format=cjs',
        '--minify-syntax',
        '-o',
        output,
      ],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(transformed.status, transformed.stderr).toBe(0);
    const mode = transformed.stderr
      .split(/\r?\n/)
      .find(
        (line) =>
          line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('input.js'),
      );
    expect(mode, transformed.stderr).toContain('semantic_graph=reanalyzed');
    const report = transformed.stderr
      .split(/\r?\n/)
      .find(
        (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('input.js'),
      );
    expect(report, transformed.stderr).toMatch(/clean=1(?:\s|$)/);
    const code = readFileSync(output, 'utf8');
    expect(code).toMatch(/function\s*\(_obj\$3\)\s*\{/);
    expect(code).not.toContain('__zntc_object_home');

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
  });

  test('bundler object-super home names survive ten hostile collision and scope inputs', async () => {
    const cases = [
      {
        name: 'three consecutive module collisions',
        files: {
          'input.js': `var _obj='a', _obj$1='b', _obj$2='c';
var base={read(){return this.x}};
var methods={read(){return [super.read(),_obj,_obj$1,_obj$2].join(':')}};
Object.setPrototypeOf(methods,base);
console.log(methods.read.call({x:'v'}));`,
        },
        homeName: '_obj$3',
        clean: true,
      },
      {
        name: 'sparse module collisions leave the base name free',
        files: {
          'input.js': `var _obj$1='a', _obj$3='b';
var base={read(){return this.x}};
var methods={read(){return [super.read(),_obj$1,_obj$3].join(':')}};
Object.setPrototypeOf(methods,base);
console.log(methods.read.call({x:'v'}));`,
        },
        homeName: '_obj',
        clean: true,
      },
      {
        name: 'a single occupied suffix is skipped',
        files: {
          'input.js': `var _obj='a', _obj$2='b';
var base={read(){return this.x}};
var methods={read(){return [super.read(),_obj,_obj$2].join(':')}};
Object.setPrototypeOf(methods,base);
console.log(methods.read.call({x:'v'}));`,
        },
        homeName: '_obj$1',
        clean: true,
      },
      {
        name: 'two wrappers share a scope with a source collision',
        files: {
          'input.js': `var _obj='a';
var base={read(){return this.x}};
var methods={a(){return super.read()},b(){return super.read()+1}};
Object.setPrototypeOf(methods,base);
console.log(methods.a.call({x:4}),methods.b.call({x:4}),_obj);`,
        },
        homeName: '_obj$1',
        clean: true,
      },
      {
        name: 'nested function has its own occupied suffix',
        files: {
          'input.js': `var _obj='outer';
var base={read(){return this.x}};
function f(){var _obj$1='inner';var methods={read(){return [super.read(),_obj,_obj$1].join(':')}};Object.setPrototypeOf(methods,base);return methods.read.call({x:'v'});}
console.log(f(),_obj);`,
        },
        homeName: '_obj$2',
        clean: true,
      },
      {
        name: 'generator state-machine callback scope',
        files: {
          'input.js': `var _obj='a',_obj$1='b',_obj$2='c';
var base={read(){return this.x}};
function* f(){var methods={read(){return [super.read(),_obj,_obj$1,_obj$2].join(':')}};Object.setPrototypeOf(methods,base);yield methods.read.call({x:'v'});}
console.log(f().next().value);`,
        },
        homeName: '_obj$3',
        clean: true,
      },
      {
        name: 'computed object-method key',
        files: {
          'input.js': `var _obj='a',_obj$1='b';var key='read';
var base={read(){return this.x}};
var methods={[key](){return [super.read(),_obj,_obj$1].join(':')}};
Object.setPrototypeOf(methods,base);
console.log(methods.read.call({x:'v'}));`,
        },
        homeName: '_obj$2',
        clean: true,
      },
      {
        name: 'async function owner',
        files: {
          'input.js': `var _obj='a',_obj$1='b';
var base={read(){return this.x}};
async function f(){var methods={read(){return [super.read(),_obj,_obj$1].join(':')}};Object.setPrototypeOf(methods,base);return methods.read.call({x:'v'});}
f().then(console.log);`,
        },
        homeName: '_obj$2',
        clean: true,
      },
      {
        name: 'imported module scope after graph linking',
        files: {
          'package.json': '{"type":"module"}',
          'input.js': `import {run} from './dep.js';console.log(run());`,
          'dep.js': `var _obj='a',_obj$1='b';var base={read(){return this.x}};var methods={read(){return [super.read(),_obj,_obj$1].join(':')}};Object.setPrototypeOf(methods,base);export function run(){return methods.read.call({x:'v'});}`,
        },
        homeName: '_obj$2',
        clean: true,
      },
      {
        name: 'direct eval stays on its early-name fallback',
        files: {
          'input.js': `var base={read(){return this.x}};
function f(){eval("var _obj='dynamic'");var methods={read(){return [super.read(),_obj].join(':')}};Object.setPrototypeOf(methods,base);return methods.read.call({x:'v'});}
console.log(f());`,
        },
        homeName: '_obj2',
        clean: false,
      },
    ];

    for (const item of cases) {
      const fixture = await createFixture(item.files);
      try {
        const output = join(fixture.dir, 'out.cjs');
        const native = spawnSync('node', [join(fixture.dir, 'input.js')], {
          cwd: fixture.dir,
          encoding: 'utf8',
        });
        expect(native.status, `${item.name}: ${native.stderr}`).toBe(0);
        const transformed = spawnSync(
          ZNTC_BIN,
          [
            '--bundle',
            'input.js',
            '--target=es5',
            '--platform=node',
            '--format=cjs',
            '--minify-syntax',
            '-o',
            output,
          ],
          {
            cwd: fixture.dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          },
        );
        expect(transformed.status, `${item.name}: ${transformed.stderr}`).toBe(0);
        const mode = transformed.stderr
          .split(/\r?\n/)
          .find((line) => line.startsWith('zntc: symbol-identity-prepass-mode '));
        expect(mode, `${item.name}: ${transformed.stderr}`).toContain('semantic_graph=reanalyzed');
        const report = transformed.stderr
          .split(/\r?\n/)
          .find((line) => line.startsWith('zntc: symbol-identity-prepass '));
        expect(report, `${item.name}: ${transformed.stderr}`).toBeDefined();
        if (item.clean) {
          expect(report, item.name).toMatch(/clean=1(?:\s|$)/);
          expect(report, item.name).toMatch(/unclassified_reference=0(?:\s|$)/);
        } else {
          // This source intentionally reaches the existing dynamic-scope debt;
          // the generated home name and runtime behavior must still match main.
          expect(report, item.name).toMatch(/unclassified_reference=1(?:\s|$)/);
          expect(report, item.name).toMatch(/clean=0(?:\s|$)/);
        }

        const code = readFileSync(output, 'utf8');
        expect(code, item.name).toContain(`Object.getPrototypeOf(${item.homeName})`);
        expect(code, item.name).not.toContain('__zntc_object_home');
        const actual = spawnSync('node', [output], { cwd: fixture.dir, encoding: 'utf8' });
        expect(actual.status, `${item.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, item.name).toBe(native.stdout);
      } finally {
        await fixture.cleanup();
      }
    }
  });

  test('function-scoped home temps bind their writes and reads to one exact SymbolId', async () => {
    const fixture = await createFixture({
      'input.js': `var _a = 'outer-a';
var _b = 'outer-b';
var base = { read() { return this.input; } };
function make() {
  var methods = {
    input: this.input,
    read() { return super.read(); },
  };
  Object.setPrototypeOf(methods, base);
  return methods.read.call({ input: 41 });
}
console.log(make.call({ input: 7 }), _a, _b);`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const native = spawnSync('node', [join(fixture.dir, 'input.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
    const transformed = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '-o', output], {
      cwd: fixture.dir,
      env: {
        ...process.env,
        ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
        ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
      },
      encoding: 'utf8',
    });
    expect(transformed.status, transformed.stderr).toBe(0);

    const lines = transformed.stderr.split(/\r?\n/);
    const report = lines.find(
      (line) => line.startsWith('zntc: symbol-identity ') && line.includes('input.js'),
    );
    expect(report, transformed.stderr).toMatch(/generated_bindings=1(?:\s|$)/);
    expect(report, transformed.stderr).toMatch(/generated_references=[2-9]\d*(?:\s|$)/);
    expect(report, transformed.stderr).toMatch(/clean=1(?:\s|$)/);
    const strict = lines.find(
      (line) => line.startsWith('zntc: synthetic-coverage ') && line.includes('input.js'),
    );
    expect(strict, transformed.stderr).toMatch(/symbol_identity_complete=1(?:\s|$)/);

    const code = readFileSync(output, 'utf8');
    expect(code).toMatch(/function make\(\) \{\s*var _c;/);
    expect(code).toContain('Object.getPrototypeOf(_c)');
    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
    expect(actual.stdout).toBe('41 outer-a outer-b\n');
  });

  test('lowered synchronous defaults bind object-super home temps in the emitted function scope', async () => {
    const fixture = await createFixture({
      'input.js': `var _a = 'outer-a';
var _b = 'outer-b';
function make(input = {
  __proto__: this.base,
  receiver: this,
  method() { return super.value + 2; },
}) {
  return input.method.call(input.receiver);
}
console.log(make.call({ base: { value: 40 } }), _a, _b);`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const native = spawnSync('node', [join(fixture.dir, 'input.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
    const transformed = spawnSync(
      ZNTC_BIN,
      ['input.js', '--target=es5', '--minify-identifiers', '-o', output],
      {
        cwd: fixture.dir,
        env: {
          ...process.env,
          ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
          ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
        },
        encoding: 'utf8',
      },
    );
    expect(transformed.status, transformed.stderr).toBe(0);

    const lines = transformed.stderr.split(/\r?\n/);
    const report = lines.find(
      (line) => line.startsWith('zntc: symbol-identity ') && line.includes('input.js'),
    );
    expect(report, transformed.stderr).toMatch(/generated_bindings=1(?:\s|$)/);
    expect(report, transformed.stderr).toMatch(/clean=1(?:\s|$)/);
    const strict = lines.find(
      (line) => line.startsWith('zntc: synthetic-coverage ') && line.includes('input.js'),
    );
    expect(strict, transformed.stderr).toMatch(/orphan_symbols=0(?:\s|$)/);
    expect(strict, transformed.stderr).toMatch(/symbol_identity_complete=1(?:\s|$)/);

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
    expect(actual.stdout).toBe('42 outer-a outer-b\n');
  });

  test('async and generator home temps wait for their generated callback scopes', async () => {
    const fixture = await createFixture({
      'input.js': `var _a = 'outer-a';
var _b = 'outer-b';
var base = { read() { return this.input; } };
function* makeGenerator() {
  var methods = {
    input: this.input,
    read() { return super.read(); },
  };
  Object.setPrototypeOf(methods, base);
  yield methods.read.call({ input: 41 });
}
class AsyncFactory {
  async make() {
    var methods = {
      input: this.input,
      read() { return super.read(); },
    };
    Object.setPrototypeOf(methods, base);
    return methods.read.call({ input: 42 });
  }
}
class GeneratorFactory {
  *make() {
    var methods = {
      input: this.input,
      read() { return super.read(); },
    };
    Object.setPrototypeOf(methods, base);
    yield methods.read.call({ input: 45 });
  }
}
function makeAsyncArrow() {
  var run = async () => {
    var methods = {
      input: this.input,
      read() { return super.read(); },
    };
    Object.setPrototypeOf(methods, base);
    return methods.read.call({ input: 43 });
  };
  return run();
}
async function makeAsyncWithNestedSyncFunction() {
  function nested() {
    var methods = {
      input: this.input,
      read() { return super.read(); },
    };
    Object.setPrototypeOf(methods, base);
    return methods.read.call({ input: 44 });
  }
  return nested();
}
var generatorValue = makeGenerator.call({ input: 7 }).next().value;
var generatorMethodValue = GeneratorFactory.prototype.make.call({ input: 8 }).next().value;
Promise.all([
  AsyncFactory.prototype.make.call({ input: 9 }),
  makeAsyncArrow.call({ input: 10 }),
  makeAsyncWithNestedSyncFunction.call({ input: 11 }),
]).then((asyncValues) => console.log(generatorValue, generatorMethodValue, ...asyncValues, _a, _b));`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const native = spawnSync('node', [join(fixture.dir, 'input.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
    const transformed = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '-o', output], {
      cwd: fixture.dir,
      env: {
        ...process.env,
        ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
        ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
      },
      encoding: 'utf8',
    });
    expect(transformed.status, transformed.stderr).toBe(0);

    const lines = transformed.stderr.split(/\r?\n/);
    const report = lines.find(
      (line) => line.startsWith('zntc: symbol-identity ') && line.includes('input.js'),
    );
    expect(report, transformed.stderr).toMatch(/clean=1(?:\s|$)/);
    const strict = lines.find(
      (line) => line.startsWith('zntc: synthetic-coverage ') && line.includes('input.js'),
    );
    expect(strict, transformed.stderr).toMatch(/orphan_symbols=0(?:\s|$)/);
    expect(strict, transformed.stderr).toMatch(/symbol_identity_complete=1(?:\s|$)/);

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
    expect(actual.stdout).toBe('41 45 42 43 44 outer-a outer-b\n');
  });

  test('home temp scope detection stops at the nearest function owner across eleven hostile shapes', async () => {
    const homeBody = (value: number) => `var methods = {
  input: 0,
  read() { return super.read(); },
};
Object.setPrototypeOf(methods, base);
return methods.read.call({ input: ${value} });`;
    const cases = [
      {
        name: 'async outer with a nested function declaration',
        source: `async function outer() {
  function nested() { ${homeBody(1)} }
  return nested();
}
outer().then((value) => console.log(value, _c, _c2));`,
      },
      {
        name: 'async outer with a nested function expression',
        source: `async function outer() {
  var nested = function() { ${homeBody(2)} };
  return nested();
}
outer().then((value) => console.log(value, _c, _c2));`,
      },
      {
        name: 'two levels of nested synchronous functions',
        source: `async function outer() {
  function middle() {
    function inner() { ${homeBody(3)} }
    return inner();
  }
  return middle();
}
outer().then((value) => console.log(value, _c, _c2));`,
      },
      {
        name: 'async class method with a nested synchronous function',
        source: `class Outer {
  async run() {
    function nested() { ${homeBody(4)} }
    return nested();
  }
}
Outer.prototype.run.call({ input: 0 }).then((value) => console.log(value, _c, _c2));`,
      },
      {
        name: 'async arrow with a nested synchronous function',
        source: `var outer = async () => {
  function nested() { ${homeBody(5)} }
  return nested();
};
outer().then((value) => console.log(value, _c, _c2));`,
      },
      {
        name: 'generator function with a nested synchronous function',
        source: `function* outer() {
  function nested() { ${homeBody(6)} }
  yield nested();
}
var iterator = outer();
console.log(iterator.next().value, _c, _c2);`,
      },
      {
        name: 'generator method with a nested synchronous function',
        source: `class Outer {
  *run() {
    function nested() { ${homeBody(7)} }
    yield nested();
  }
}
var iterator = Outer.prototype.run.call({ input: 0 });
console.log(iterator.next().value, _c, _c2);`,
      },
      {
        name: 'async function inside async function with a nested sync leaf',
        source: `async function outer() {
  async function middle() {
    function nested() { ${homeBody(8)} }
    return nested();
  }
  return middle();
}
outer().then((value) => console.log(value, _c, _c2));`,
      },
      {
        name: 'synchronous class method inside an async owner',
        source: `async function outer() {
  class Inner {
    run() { ${homeBody(9)} }
  }
  return new Inner().run();
}
outer().then((value) => console.log(value, _c, _c2));`,
      },
      {
        name: 'try and catch block inside a nested synchronous function',
        source: `async function outer() {
  function nested() {
    try { throw 1; } catch (error) { ${homeBody(10)} }
  }
  return nested();
}
outer().then((value) => console.log(value, _c, _c2));`,
      },
      {
        name: 'default parameter object in a nested synchronous function',
        source: `async function outer() {
  function nested(methods = { __proto__: base, read() { return super.read(); } }) {
    return methods.read.call({ input: 11 });
  }
  return nested();
}
outer().then((value) => console.log(value, _c, _c2));`,
      },
    ];
    const prefix = `var _c = 'source-c';
var _c2 = 'source-c2';
var base = { read() { return this.input; } };
`;

    for (const item of cases) {
      const fixture = await createFixture({ 'input.js': prefix + item.source });
      try {
        const output = join(fixture.dir, 'out.js');
        const native = spawnSync('node', [join(fixture.dir, 'input.js')], {
          cwd: fixture.dir,
          encoding: 'utf8',
        });
        expect(native.status, `${item.name}: ${native.stderr}`).toBe(0);
        const transformed = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '-o', output], {
          cwd: fixture.dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        });
        expect(transformed.status, `${item.name}: ${transformed.stderr}`).toBe(0);
        const report = transformed.stderr
          .split(/\r?\n/)
          .find((line) => line.startsWith('zntc: symbol-identity ') && line.includes('input.js'));
        expect(report, `${item.name}: ${transformed.stderr}`).toMatch(/missing_binding=0(?:\s|$)/);
        expect(report, `${item.name}: ${transformed.stderr}`).toMatch(
          /unclassified_reference=0(?:\s|$)/,
        );
        expect(report, item.name).toMatch(/clean=1(?:\s|$)/);
        const actual = spawnSync('node', [output], { cwd: fixture.dir, encoding: 'utf8' });
        expect(actual.status, `${item.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, item.name).toBe(native.stdout);
      } finally {
        await fixture.cleanup();
      }
    }
  });

  test('computed super compound, nullish, and postfix temps keep identity and evaluation order', async () => {
    const fixture = await createFixture({
      'input.js': `var events = [];
var keyCalls = 0;
var _a = 'outer-a';
var _b = 'outer-b';
function key() { keyCalls++; events.push('key'); return 'value'; }
class Base {
  get value() { events.push('get'); return this.stored; }
  set value(next) { events.push('set:' + next); this.stored = next; }
}
class Child extends Base {
  compound(delta) { return super[key()] += delta; }
  postfix() { return super[key()]++; }
  nullish() { return super[key()] ??= 8; }
  *sequence() { yield super[key()] += 1; yield super[key()]++; yield super[key()] ??= 8; }
}
var child = new Child();
child.stored = 10;
var compound = child.compound(2);
var postfix = child.postfix();
child.stored = null;
var nullish = child.nullish();
child.stored = 20;
var iterator = child.sequence();
var generatorValues = [iterator.next().value, iterator.next().value];
child.stored = null;
generatorValues.push(iterator.next().value);
console.log([compound, postfix, nullish, child.stored, generatorValues.join(','), keyCalls, events.join(','), _a, _b].join('|'));`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const native = spawnSync('node', [join(fixture.dir, 'input.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
    const transformed = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '-o', output], {
      cwd: fixture.dir,
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
      encoding: 'utf8',
    });
    expect(transformed.status, transformed.stderr).toBe(0);

    const report = transformed.stderr
      .split(/\r?\n/)
      .find((line) => line.startsWith('zntc: symbol-identity ') && line.includes('input.js'));
    expect(report, transformed.stderr).toMatch(/clean=1(?:\s|$)/);
    expect(report, transformed.stderr).toMatch(/missing_binding=0(?:\s|$)/);
    expect(report, transformed.stderr).toMatch(/unclassified_reference=0(?:\s|$)/);

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
    expect(actual.stdout).toBe(
      '12|12|8|8|21,21,8|6|key,get,set:12,key,get,set:13,key,get,set:8,key,get,set:21,key,get,set:22,key,get,set:8|outer-a|outer-b\n',
    );
  });

  test('escaped direct eval names stay reserved for the home parameter', async () => {
    const fixture = await createFixture({
      'input.js': `var base = { read() { return this.input; } };
var methods = { read() { return [super.read(), eval('typeof \\u005fobj')].join(':'); } };
Object.setPrototypeOf(methods, base);
console.log(methods.read.call({ input: 41 }));`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const native = spawnSync('node', [join(fixture.dir, 'input.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
    const transformed = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '-o', output], {
      cwd: fixture.dir,
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
      encoding: 'utf8',
    });
    expect(transformed.status, transformed.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    expect(code).toMatch(/function\s*\(_obj2\)\s*\{/);
    expect(code).not.toContain('__zntc_object_home');
    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
    expect(actual.stdout.trim()).toBe('41:undefined');
  });
});
