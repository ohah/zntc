import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5659: an arrow's cover-grammar default parameter `(a = 1) =>` stayed an
// assignment expression, so ES5 lowering turned the arrow into
// `function(a = 1)` — ES2015 syntax that real ES5 engines reject. Node and
// Hermes accept it, which is why runtime tests missed it. The parameter is now
// lowered like a function's (`a = a === void 0 ? 1 : a`). Node prints the
// expected output; the output must also contain no parameter default.
const cases = {
  'single default': {
    source: 'const f = (a = 1) => a;\nconsole.log(f(), f(5));',
    expected: '1 5\n',
  },
  'default after a plain parameter': {
    source: 'const f = (x, a = x + 1) => [x, a];\nconsole.log(JSON.stringify([f(1), f(1, 9)]));',
    expected: '[[1,2],[1,9]]\n',
  },
  'default reading an outer binding shadowed by a body var': {
    source:
      "function make() { var q = 3; const f = (a = q) => { var q = 'inner'; return [a, q]; }; return f(); }\nconsole.log(JSON.stringify(make()));",
    expected: '[3,"inner"]\n',
  },
  'default with this and arguments in the enclosing function': {
    source:
      "function outer() { const f = (a = this.v, b = arguments[0]) => [a, b]; return f(); }\nconsole.log(JSON.stringify(outer.call({ v: 'this' }, 'arg')));",
    expected: '["this","arg"]\n',
  },
  'async arrow default': {
    source: 'const f = async (a = 1) => a + 1;\nf().then((v) => console.log(v));',
    expected: '2\n',
  },
} as const;

describe('ES5 lowers arrow function default parameters (#5659)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const mode of ['transform', 'transform-minify', 'bundle']) {
    for (const [name, { source, expected }] of Object.entries(cases)) {
      test(`${name}, ${mode}`, async () => {
        const created = await createFixture({ 'entry.js': source });
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.js');
        const args = mode === 'bundle' ? ['--bundle'] : [];
        if (mode === 'transform-minify') args.push('--minify');
        const result = await runZntc([
          ...args,
          join(created.dir, 'entry.js'),
          '--target=es5',
          '-o',
          out,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const code = await Bun.file(out).text();
        // No `(name = …)` default in an emitted function parameter list.
        expect(code).not.toMatch(/function\s*[\w$]*\s*\([^)]*\b[\w$]+\s*=[^=]/);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected);
      });
    }
  }
});
