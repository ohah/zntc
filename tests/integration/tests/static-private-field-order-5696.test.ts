import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5696: static fields, static blocks and static private fields run in source
// order. A lowered static private field became a descriptor
// (`var _x = { value: … }`) emitted right after the class, ahead of the
// preceding static fields and blocks. Node runs the sources natively for the
// expected output.
const cases: Record<string, string> = {
  'private fields between blocks and fields':
    "const log = [];\nclass A { static a = log.push('f0'); static { log.push('block'); } static #x = log.push('pfield'); static y = log.push('field'); static { log.push('b2'); } static #z = log.push('pz'); static get x() { return A.#x + A.#z; } static #m() {} }\nconsole.log(log.join(), A.x);\n",
  'private methods exist before the first initializer':
    "const log = [];\nclass P { static base = 10; }\nclass A extends P {\n  static #x = A.#m() + super.base + this.base;\n  static #m() { return 'm'; }\n  static get x() { return A.#x; }\n}\nlog.push(A.x);\nconsole.log(log.join());\n",
  'a block reading a later private field throws':
    'const log = [];\nclass A {\n  static { try { log.push(A.#late); } catch (e) { log.push(e.constructor.name); } }\n  static #late = 1;\n  static get late() { return A.#late; }\n}\nlog.push(A.late);\nconsole.log(log.join());\n',
  'class expressions':
    "const log = [];\nconst B = class { static { log.push('block'); } static #y = log.push('y'); static z = log.push('z'); static get y() { return this.#y; } };\nconsole.log(log.join(), B.y);\n",
};

const argSets = ['es2021', 'es2015', 'es5'].flatMap((t) => [
  [`--target=${t}`],
  [`--target=${t}`, '--minify'],
  ['--bundle', `--target=${t}`],
]);

describe('static private field initialization order (#5696)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, source] of Object.entries(cases)) {
    for (const args of argSets) {
      test(`${name}, ${args.join(' ')}`, async () => {
        const created = await createFixture({ 'entry.js': source });
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(created.dir, 'out.cjs');
        const result = await runZntc([join(created.dir, 'entry.js'), ...args, '-o', out]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected.stdout);
      });
    }
  }
});
