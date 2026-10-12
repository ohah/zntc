import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

describe('lexical arrow captures in dynamic with scopes (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('keeps lexical captures intact when with can intercept generated aliases', async () => {
    const fixture = await createFixture({
      'input.js': `
function Outer(a, b) {
  this.value = 7;
  with ({
    _arguments: { length: 99 },
    _this: { value: 99 },
    _newTarget: 'intercepted',
  }) {
    this.capture = [
      () => argum\\u0065nts.length,
      () => this.value,
      () => new.target === Outer,
    ];
  }
}
const instance = new Outer(1, 2);
console.log(instance.capture.map((read) => read()).join(' '));
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.cjs');
    const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '--format=cjs', '-o', output], {
      cwd: fixture.dir,
      encoding: 'utf8',
    });
    expect(proc.status, proc.stderr).toBe(0);
    expect(proc.stderr).toContain(
      'a lexical-capturing arrow or its containing class/object literal inside a with statement is emitted unchanged',
    );

    const code = readFileSync(output, 'utf8');
    expect(code.match(/=>/g)?.length).toBe(3);
    expect(code).not.toMatch(/var _arguments\s*=\s*arguments\b/);
    expect(code).not.toMatch(/var _this\s*=\s*this\b/);

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe('2 7 true\n');
  });

  test('still lowers arrows in with bodies when no lexical capture is needed', async () => {
    const fixture = await createFixture({
      'input.js': `
function read(object) {
  with (object) {
    return (() => value)();
  }
}
console.log(read({ value: 7 }));
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.cjs');
    const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '--format=cjs', '-o', output], {
      cwd: fixture.dir,
      encoding: 'utf8',
    });
    expect(proc.status, proc.stderr).toBe(0);
    expect(proc.stderr).not.toContain('lexical-capturing arrow inside a with statement');
    expect(readFileSync(output, 'utf8')).not.toContain('=>');

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe('7\n');
  });

  test('preserves async arrows when only async syntax needs downleveling', async () => {
    const fixture = await createFixture({
      'input.js': `
function read(a, b) {
  with ({ _arguments: { length: 99 } }) {
    return (async () => arguments.length)();
  }
}
read(1, 2).then((length) => console.log(length));
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.cjs');
    const proc = spawnSync(
      ZNTC_BIN,
      ['input.js', '--target=es2015', '--format=cjs', '-o', output],
      {
        cwd: fixture.dir,
        encoding: 'utf8',
      },
    );
    expect(proc.status, proc.stderr).toBe(0);
    expect(proc.stderr).toContain('lexical-capturing arrow or its containing class/object literal');
    expect(readFileSync(output, 'utf8')).toMatch(/async\s*\(\)\s*=>/);

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe('2\n');
  });

  test('visits a with object expression outside the dynamic body scope', async () => {
    const fixture = await createFixture({
      'input.js': `
function read(a, b) {
  with ((() => ({ value: arguments.length }))()) {
    return value;
  }
}
console.log(read(1, 2));
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.cjs');
    const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '--format=cjs', '-o', output], {
      cwd: fixture.dir,
      encoding: 'utf8',
    });
    expect(proc.status, proc.stderr).toBe(0);
    expect(proc.stderr).not.toContain('lexical-capturing arrow inside a with statement');
    expect(readFileSync(output, 'utf8')).not.toContain('=>');

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe('2\n');
  });

  test('detects captures in class heritage evaluated from an outer arrow', async () => {
    const fixture = await createFixture({
      'input.js': `
function Good() { this.kind = 'good'; }
function Bad() { this.kind = 'bad'; }
function Outer() {
  this.Base = Good;
  with ({ _this: { Base: Bad } }) {
    this.make = () => class extends (() => this.Base)() {};
  }
}
const make = new Outer().make;
const Child = make();
console.log(new Child().kind);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.cjs');
    const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '--format=cjs', '-o', output], {
      cwd: fixture.dir,
      encoding: 'utf8',
    });
    expect(proc.status, proc.stderr).toBe(0);
    expect(proc.stderr).toContain(
      'lexical-capturing arrow or its containing class/object literal inside a with statement',
    );
    expect(readFileSync(output, 'utf8')).toContain('=>');

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe('good\n');
  });

  test('detects captures in computed class keys without crossing method bodies', async () => {
    const fixture = await createFixture({
      'input.js': `
function Outer() {
  this.key = 'good';
  with ({ _this: { key: 'bad' } }) {
    this.create = () => class { [(() => this.key)()]() {} };
  }
}
const create = new Outer().create;
const Example = create();
console.log(typeof Example.prototype.good);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.cjs');
    const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '--format=cjs', '-o', output], {
      cwd: fixture.dir,
      encoding: 'utf8',
    });
    expect(proc.status, proc.stderr).toBe(0);
    expect(proc.stderr).toContain('lexical-capturing arrow or its containing class/object literal');

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe('function\n');
  });

  test('does not treat ordinary method this as an outer arrow capture', async () => {
    const fixture = await createFixture({
      'input.js': `
function Outer() {
  with ({ _this: { value: 99 } }) {
    this.create = () => class { read() { return this.value; } };
  }
}
const create = new Outer().create;
const Example = create();
console.log(new Example().read.call({ value: 7 }));
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.cjs');
    const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '--format=cjs', '-o', output], {
      cwd: fixture.dir,
      encoding: 'utf8',
    });
    expect(proc.status, proc.stderr).toBe(0);
    expect(proc.stderr).not.toContain('lexical-capturing arrow inside a with statement');

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe('7\n');
  });

  test('bundler preserves with-scoped captures and reports the target limitation', async () => {
    const fixture = await createFixture({
      'dep.cjs': `
module.exports = function run() {
function Outer(a, b) {
  this.value = 7;
  with ({ _arguments: { length: 99 }, _this: { value: 99 } }) {
    this.read = () => [arguments.length, this.value];
  }
}
const read = new Outer(1, 2).read;
console.log(read().join(' '));
};
`,
      'index.mjs': "import run from './dep.cjs'; run();",
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.cjs');
    const bundle = spawnSync(
      ZNTC_BIN,
      ['--bundle', 'index.mjs', '--target=es5', '--format=cjs', '-o', output],
      { cwd: fixture.dir, encoding: 'utf8' },
    );

    expect(bundle.status, bundle.stderr).toBe(0);
    expect(bundle.stderr).toContain(
      'lexical-capturing arrow or its containing class/object literal inside a with statement',
    );
    expect(readFileSync(output, 'utf8')).toContain('=>');
  });

  test('keeps lexical super valid when an arrow is nested in a with-scoped class method', async () => {
    const fixture = await createFixture({
      'input.js': `
function Base() {}
Base.prototype.value = function () { return 'base'; };
with ({ __superGet: function () { return function () { return 'intercepted'; }; } }) {
  class Child extends Base {
    method() { return () => super.value(); }
  }
  const read = Child.prototype.method.call(new Child());
  console.log(read());
}
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.cjs');
    const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '--format=cjs', '-o', output], {
      cwd: fixture.dir,
      encoding: 'utf8',
    });
    expect(proc.status, proc.stderr).toBe(0);
    expect(proc.stderr).toContain(
      'lexical-capturing arrow or its containing class/object literal inside a with statement',
    );

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe('base\n');
  });

  test('keeps lexical super valid when an arrow is nested in a with-scoped object method', async () => {
    const fixture = await createFixture({
      'input.js': `
function Base() {}
Base.prototype.value = function () { return 'base'; };
var read;
with ({ __superGet: function () { return function () { return 'intercepted'; }; } }) {
  var object = {
    __proto__: Base.prototype,
    method() { return () => super.value(); },
  };
  read = object.method();
}
console.log(read());
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.cjs');
    const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '--format=cjs', '-o', output], {
      cwd: fixture.dir,
      encoding: 'utf8',
    });
    expect(proc.status, proc.stderr).toBe(0);
    expect(proc.stderr).toContain('containing class/object literal');

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe('base\n');
  });
});
