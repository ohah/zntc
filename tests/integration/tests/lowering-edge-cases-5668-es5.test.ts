import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5668 (4, 5, 7, 8): more ES5 lowering edge cases. Node runs the sources
// natively for the expected output.
//  4. An expanded shorthand `{x}` gave its key the reference's symbol, so
//     constant inlining rewrote the key (`{1: x}`).
//  5. A block function aliasing the function-scope binding (#2714) was renamed
//     as a block binding; identifier minification then renamed the
//     declaration but not the references outside the block.
//  7. A rest parameter pattern (`...[c, d = c]`) stayed on the `var`.
//  8. A block binding lowered to the function body captured a parameter of the
//     same name read by a default's closure.
//  6. A sloppy function with a non-simple parameter list has unmapped
//     `arguments`; lowered defaults made the parameters mapped again
//     (`a = 2` changed `arguments[0]`). Such parameters now bind body `var`s.
const cases: Record<string, string> = {
  'shorthand keys with inlined constants':
    "import { y } from './dep.mjs';\nconst x = 1;\nfunction f() { var a = {x, y}; let z = 3; { let z = 4; var b = {z}; } return [a.x, a.y, b.z]; }\nconsole.log(JSON.stringify(f()), JSON.stringify({y}));\n",
  'block function declarations':
    'function f() { { function a() { return 1; } } return typeof a; }\nconsole.log(f(), f.call(null));\n',
  'rest parameter patterns':
    'function f(...[c, d = c]) { return [c, d]; }\nfunction g(a, ...{ length, 0: z }) { return [a, length, z]; }\nconst h = (...[x, ...y]) => [x, y];\nconsole.log(JSON.stringify([f(1), g(1, 2, 3), h(1, 2, 3)]));\n',
  'block bindings named like parameters':
    'function g(p, q = () => p) { { let p = 2; } return q(); }\nfunction h(p, q = () => p) { { const p = 2; } for (let p of [3]) {} { class p {} } return q(); }\nfunction k(p = 1) { { let p = 5; var r = p; } return [p, r]; }\nconsole.log(g(1), h(1), JSON.stringify(k()));\n',
};

describe('ES5 lowering edge cases (#5668)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, source] of Object.entries(cases)) {
    for (const args of [
      [],
      ['--minify'],
      ['--minify-identifiers'],
      ['--minify-syntax'],
      ['--bundle'],
    ]) {
      test(`${name}, es5 ${args.join(' ')}`, async () => {
        const file = name.startsWith('shorthand') ? 'entry.mjs' : 'entry.js';
        const files: Record<string, string> = { [file]: source };
        if (file === 'entry.mjs') files['dep.mjs'] = "const y = 'dy';\nexport { y };";
        const created = await createFixture(files);
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, file)], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(created.dir, file === 'entry.mjs' ? 'out.mjs' : 'out.js');
        const result = await runZntc([join(created.dir, file), '--target=es5', ...args, '-o', out]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected.stdout);
      });
    }
  }
});
