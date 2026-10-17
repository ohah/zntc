import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

const cases = [
  {
    name: 'class decorator',
    target: 'es2022',
    source: [
      'const events: string[] = [];',
      'function dec(value: any) { events.push(`class:${value.value}`); return value; }',
      "@dec export default class { static value = (events.push('field'), 1); }",
      "console.log(events.join(','));",
    ].join('\n'),
    expected: 'field,class:1\n',
  },
  {
    name: 'member decorator',
    target: 'es2022',
    source: [
      'const events: string[] = [];',
      'function dec(_target: any, key: string) { events.push(`member:${key}`); }',
      "export default class { @dec method() {} static value = (events.push('field'), 1); }",
      "console.log(events.join(','));",
    ].join('\n'),
    expected: 'field,member:method\n',
  },
  {
    name: 'property decorator',
    target: 'es2022',
    source: [
      'const events: string[] = [];',
      'function dec(_target: any, key: string) { events.push(`property:${key}`); }',
      "export default class { @dec value = 2; static field = (events.push('field'), 1); }",
      "console.log(events.join(','));",
    ].join('\n'),
    expected: 'field,property:value\n',
  },
  {
    name: 'constructor parameter decorator',
    target: 'es2022',
    source: [
      'const events: string[] = [];',
      'function dec(_target: any, _key: string | undefined, index: number) { events.push(`parameter:${index}`); }',
      "export default class { constructor(@dec _value: string) {} static value = (events.push('field'), 1); }",
      "console.log(events.join(','));",
    ].join('\n'),
    expected: 'field,parameter:0\n',
  },
  {
    name: 'class decorator with a lowered static private field',
    target: 'es2015',
    source: [
      'const events: string[] = [];',
      'function dec(value: any) { events.push(`class:${value.value}`); return value; }',
      "@dec export default class { static #secret = (events.push('private-field'), 1); static value = this.#secret; }",
      "console.log(events.join(','));",
    ].join('\n'),
    expected: 'private-field,class:1\n',
  },
  {
    name: 'class and member decorators',
    target: 'es2022',
    source: [
      'const events: string[] = [];',
      'function classDec(value: any) { events.push(`class:${value.value}`); return value; }',
      'function memberDec(_target: any, key: string) { events.push(`member:${key}`); }',
      "@classDec export default class { @memberDec method() {} static value = (events.push('field'), 1); }",
      "console.log(events.join(','));",
    ].join('\n'),
    expected: 'field,member:method,class:1\n',
  },
  {
    name: 'ES5 class, member, property, and constructor parameter decorators',
    target: 'es5',
    source: [
      'const events: string[] = [];',
      'function classDec(value: any) { events.push(`class:${value.value}`); return value; }',
      'function memberDec(_target: any, key: string) { events.push(`member:${key}`); }',
      'function propertyDec(_target: any, key: string) { events.push(`property:${key}`); }',
      'function parameterDec(_target: any, _key: string | undefined, index: number) { events.push(`parameter:${index}`); }',
      '@classDec export default class {',
      '  @memberDec method() {}',
      '  @propertyDec value = 2;',
      '  constructor(@parameterDec _value: string) {}',
      "  static value = (events.push('field'), 1);",
      '}',
      "console.log(events.join(','));",
    ].join('\n'),
    expected: 'field,member:method,property:value,class:1,parameter:0\n',
  },
] as const;

describe('anonymous decorated default class scope identity (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const { name, target, source, expected } of cases) {
    test(`${name} with lowered static fields`, async () => {
      const created = await createFixture({ 'entry.ts': source });
      cleanup = created.cleanup;
      const output = join(created.dir, 'out.mjs');
      const result = await runZntc(
        [
          join(created.dir, 'entry.ts'),
          `--target=${target}`,
          '--experimental-decorators',
          '--use-define-for-class-fields=false',
          '--minify-identifiers',
          '--format=esm',
          '-o',
          output,
        ],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
      );
      expect(result.exitCode, result.stderr).toBe(0);
      const report = result.stderr
        .split(/\r?\n/)
        .find((line) => line.startsWith('zntc: symbol-identity ') && line.includes('entry.ts'));
      expect(report, result.stderr).toBeDefined();
      expect(report).toContain('scope_owner_mismatch=0');
      expect(report).toContain('scope_owner_parent_mismatch=0');
      expect(report).toMatch(/\bclean=1(?:\s|$)/);

      const run = spawnSync('node', [output], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(expected);
    });
  }
});
