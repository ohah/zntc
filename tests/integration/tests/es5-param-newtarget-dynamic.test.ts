import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, test } from 'bun:test';
import { ZNTC_BIN } from './helpers';

function compileAndRun(
  source: string,
  options: { expectedUnclassifiedReferences?: number } = {},
): { stdout: string; emitted: string } {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-es5-param-newtarget-dynamic-'));
  const input = join(dir, 'input.js');
  const output = join(dir, 'output.cjs');
  try {
    writeFileSync(input, source);
    const compiled = spawnSync(
      ZNTC_BIN,
      [input, '--platform=react-native', '--target=es5', '--format=cjs', '-o', output],
      {
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(compiled.status, compiled.stderr).toBe(0);
    const identity = compiled.stderr
      .split(/\r?\n/)
      .find((line) => line.startsWith('zntc: symbol-identity '));
    expect(identity, compiled.stderr).toBeDefined();
    if (options.expectedUnclassifiedReferences === undefined) {
      expect(identity, compiled.stderr).toMatch(/clean=1(?:\s|$)/);
    } else {
      expect(identity, compiled.stderr).toMatch(/missing_binding=0(?:\s|$)/);
      expect(identity, compiled.stderr).toMatch(/missing_reference=0(?:\s|$)/);
      expect(identity, compiled.stderr).toMatch(/invalid_id=0(?:\s|$)/);
      expect(identity, compiled.stderr).toMatch(
        new RegExp(`unclassified_reference=${options.expectedUnclassifiedReferences}(?:\\s|$)`),
      );
    }

    const emitted = readFileSync(output, 'utf8');
    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    return { stdout: actual.stdout, emitted };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe('ES5 new.target in retained native parameter environments (#4819)', () => {
  test('parameter eval keeps generated captures out of eval-visible names', () => {
    const { stdout, emitted } = compileAndRun(
      [
        "function Foo(_newTarget = 11, value = () => () => [new.target, _newTarget, eval('typeof _newTarget2')]) {",
        '  var result = value()();',
        '  this.target = result[0];',
        '  this.parameter = result[1];',
        '  this.evalName = result[2];',
        '}',
        'var instance = new Foo();',
        'console.log(instance.target === Foo, instance.parameter, instance.evalName);',
      ].join('\n'),
    );
    expect(stdout).toBe('true 11 undefined\n');
    expect(emitted).toContain('eval("typeof _newTarget2")');
  });

  test('body eval retains native defaults and their lexical new.target capture', () => {
    const { stdout } = compileAndRun(
      [
        'function Foo(value = () => () => new.target) {',
        "  eval('typeof value');",
        '  this.target = value()();',
        '}',
        'console.log(new Foo().target === Foo);',
      ].join('\n'),
    );
    expect(stdout).toBe('true\n');
  });

  test('object method parameter eval retains its own new.target boundary', () => {
    const { stdout } = compileAndRun(
      [
        "var holder = { run(value = () => () => [new.target, eval('typeof _newTarget2')]) {",
        '  return value()();',
        '} };',
        'var result = holder.run();',
        'console.log(result[0] === undefined, result[1]);',
      ].join('\n'),
    );
    expect(stdout).toBe('true undefined\n');
  });

  test('with in the body retains native defaults and their lexical new.target capture', () => {
    const { stdout } = compileAndRun(
      [
        'function Foo(value = () => () => new.target) {',
        '  with ({ marker: 7 }) { this.marker = marker; }',
        '  this.target = value()();',
        '}',
        'var instance = new Foo();',
        'console.log(instance.target === Foo, instance.marker);',
      ].join('\n'),
      { expectedUnclassifiedReferences: 1 },
    );
    expect(stdout).toBe('true 7\n');
  });

  test('ordinary ES5 default lowering still provides lexical new.target', () => {
    const { stdout } = compileAndRun(
      [
        'function Foo(value = () => () => new.target) {',
        '  this.target = value()();',
        '}',
        'console.log(new Foo().target === Foo);',
      ].join('\n'),
    );
    expect(stdout).toBe('true\n');
  });

  test('late capture naming avoids a same-named source parameter before semantic resync', () => {
    const { stdout, emitted } = compileAndRun(
      [
        'function Foo(_newTarget = 11, value = () => () => [new.target, _newTarget]) {',
        '  var result = value()();',
        '  this.target = result[0];',
        '  this.parameter = result[1];',
        '}',
        'var instance = new Foo();',
        'console.log(instance.target === Foo, instance.parameter);',
      ].join('\n'),
    );
    expect(stdout).toBe('true 11\n');
    expect(emitted).toContain('var _newTarget2 =');
    expect(emitted).toContain('[_newTarget2, _newTarget]');
  });

  test('a collision in a later function is reserved before earlier late capture resolution', () => {
    const { stdout } = compileAndRun(
      [
        'function Plain(value = () => () => new.target) { this.target = value()(); }',
        'function Foo(_newTarget = 11, value = () => () => [new.target, _newTarget]) {',
        '  var result = value()();',
        '  this.target = result[0];',
        '  this.parameter = result[1];',
        '}',
        'var plain = new Plain();',
        'var instance = new Foo();',
        'console.log(plain.target === Plain, instance.target === Foo, instance.parameter);',
      ].join('\n'),
    );
    expect(stdout).toBe('true true 11\n');
  });

  test('a nested ordinary function keeps its own new.target boundary', () => {
    const { stdout } = compileAndRun(
      [
        'function Foo(value = () => function Inner() { return new.target; }) {',
        '  this.target = value()();',
        '}',
        'console.log(new Foo().target === undefined);',
      ].join('\n'),
    );
    expect(stdout).toBe('true\n');
  });
});
