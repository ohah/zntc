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
