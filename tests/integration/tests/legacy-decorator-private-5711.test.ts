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
});
