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
