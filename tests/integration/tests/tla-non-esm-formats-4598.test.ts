import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4598: a bundle with top-level await and a non-ESM output format must keep
// module evaluation order, like webpack's async modules do in every format.
// - es2022+: cjs kept a native top-level await (it only ran when Node mistook
//   the file for ESM) and umd put one inside a sync factory (SyntaxError).
//   Top-level await is now lowered for every non-ESM format.
// - es2018-es2021: a module whose only top-level await was a `for await` loop
//   skipped the graph pre-pass, so its importer did not wait for the loop.
// - es5: importers ran before the awaited module finished (`a0,b`, exports
//   still holding their pre-await values). Like webpack, the bundle now waits
//   through async module initializers and warns that the target lacks
//   async/await.
const fixtures: Record<string, Record<string, string>> = {
  chain: {
    'a.ts': 'export const order: string[] = [];\norder.push("a0");\nawait 0;\norder.push("a1");\n',
    'b.ts': 'import { order } from "./a";\norder.push("b");\nexport const B = order;\n',
    'main.ts': 'import { B } from "./b";\nconsole.log("R:", B.join());\n',
  },
  allforms: {
    'lib.ts':
      'await Promise.resolve();\nexport function fn() { return "fn"; }\nexport class C { m() { return "C"; } }\nexport default "def";\nexport let late = "early";\nlate = await Promise.resolve("late");\n',
    'main.ts':
      'import d, { fn, C, late } from "./lib";\nconsole.log("R:", fn(), new C().m(), d, late);\n',
  },
  forawait: {
    'lib.ts':
      'async function* gen() { yield 1; yield 2; }\nexport const acc: number[] = [];\nfor await (const v of gen()) acc.push(v);\n',
    'main.ts': 'import { acc } from "./lib";\nconsole.log("R:", acc.join());\n',
  },
  repro: {
    'lib.ts':
      'const items: number[] = [];\nitems.push(1);\nawait Promise.resolve();\nexport const OUT = { items };\n',
    'main.ts': 'import { OUT } from "./lib";\nconsole.log("R:", JSON.stringify(OUT));\n',
  },
};
const expected: Record<string, string> = {
  chain: 'R: a0,a1,b\n',
  allforms: 'R: fn C def late\n',
  forawait: 'R: 1,2\n',
  repro: 'R: {"items":[1]}\n',
};

describe('top-level await keeps order in every output format (#4598)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, files] of Object.entries(fixtures)) {
    for (const format of ['iife', 'cjs', 'umd', 'esm']) {
      for (const target of ['es2022', 'es2020', 'es2017', 'es5']) {
        test(`${name} ${format} ${target}`, async () => {
          const created = await createFixture(files);
          cleanup = created.cleanup;
          const out = join(created.dir, format === 'esm' ? 'out.mjs' : 'out.cjs');
          const result = await runZntc([
            '--bundle',
            join(created.dir, 'main.ts'),
            `--format=${format}`,
            `--target=${target}`,
            '--platform=node',
            '-o',
            out,
          ]);
          expect(result.exitCode, result.stderr).toBe(0);
          const warned = result.stderr.includes('does not support async/await');
          expect(warned).toBe(target === 'es5' && format !== 'esm');
          const run = spawnSync('node', [out], { encoding: 'utf8' });
          expect(run.status, run.stderr).toBe(0);
          expect(run.stdout).toBe(expected[name]);
        });
      }
    }
  }
});
