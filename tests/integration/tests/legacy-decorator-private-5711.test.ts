import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5711: experimentalDecorators classes whose private members are lowered
// panicked ("unresolved producer-owned SymbolId references"): the legacy
// branch dropped the static private descriptors and never resolved the
// private helper references. Its static fields and blocks also ran after the
// decorators; tsc runs them first, as part of the class definition.
const decorators =
  "const log = [];\nfunction dec(...a) { log.push('dec:' + (typeof a[0] === 'function' ? a[0].y : String(a[1]))); }\n";
const cases: Record<string, { source: string; expected: string }> = {
  'class decorator with an instance private field': {
    source:
      '@dec class A { #x = 1; get x() { return this.#x; } }\nconsole.log(new A().x, log.join());\n',
    expected: '1 dec:undefined\n',
  },
  'class decorator with a static private field': {
    source:
      "@dec class A { static #x = 1; static y = log.push('y'); static get x() { return A.#x; } }\nconsole.log(A.x, log.join());\n",
    expected: '1 y,dec:1\n',
  },
  'member decorators with static private members': {
    source:
      "class A { @dec m() {} #p = 3; static #x = 1; static #m() { return 2; } static { log.push('blk'); } static get x() { return A.#x + A.#m() + new A().#p; } }\nconsole.log(A.x, log.join());\n",
    expected: '6 blk,dec:m\n',
  },
  'static elements run before the decorators': {
    source:
      "class A { @dec m() {} static y = log.push('y'); static { log.push('blk'); } }\n@dec class B { static y = log.push('By'); }\nconsole.log(log.join());\n",
    expected: 'y,blk,dec:m,By,dec:4\n',
  },
};

describe('legacy decorators with lowered private members (#5711)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, { source, expected }] of Object.entries(cases)) {
    for (const target of ['es2021', 'es2015', 'es5']) {
      test(`${name}, ${target}`, async () => {
        const created = await createFixture({ 'entry.ts': decorators + source });
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.cjs');
        const result = await runZntc([
          join(created.dir, 'entry.ts'),
          `--target=${target}`,
          '--experimental-decorators',
          '-o',
          out,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected);
      });
    }
  }

  test('anonymous default class decorator binds extracted static fields by exact SymbolId', async () => {
    const created = await createFixture({
      'entry.ts': [
        'export const events: string[] = [];',
        'function dec(value: any): any { events.push("decorated:" + value.value); return value; }',
        '@dec',
        'export default class { static value = 1; }',
      ].join('\n'),
      'consumer.mjs': [
        'import Default, { events } from "./out.mjs";',
        'console.log(events.join(","), Default.value);',
      ].join('\n'),
    });
    cleanup = created.cleanup;
    const result = await runZntc(
      [
        join(created.dir, 'entry.ts'),
        '--target=es2022',
        '--experimental-decorators',
        '--use-define-for-class-fields=false',
        '--minify-identifiers',
        '--format=esm',
        '-o',
        join(created.dir, 'out.mjs'),
      ],
      { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
    );
    expect(result.exitCode, result.stderr).toBe(0);

    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.startsWith('zntc: symbol-identity '));
    expect(identity, result.stderr).toContain('unclassified_reference=0');
    expect(identity, result.stderr).toContain('missing_reference=0');
    const postMinify = result.stderr
      .split(/\r?\n/)
      .find((line) => line.startsWith('zntc: symbol-identity-post-minify '));
    expect(postMinify, result.stderr).toContain('clean=1');

    const actual = spawnSync('node', [join(created.dir, 'consumer.mjs')], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe('decorated:1 1\n');
  });
});
