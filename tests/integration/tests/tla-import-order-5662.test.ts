import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5662: with a top-level-await module wrapped in an async `__esm` factory
// (ESM output for es2017~es2021), a module imported after it still ran first:
//  - its importer's init ran named-import inits before side-effect and
//    re-export inits (`init_b(); await init_a();`), and
//  - a module reached only through `export *` of a wrapped barrel stayed
//    scope-hoisted at the top level.
// The expected order is zntc's es2022 output, which keeps top-level await and
// matches rolldown and esbuild (\`a1 a2 b1\`; native interleaves \`a1 b1 a2\`).
const a = "console.log('a1');\nawait 0;\nconsole.log('a2');";
const cases: Record<string, Record<string, string>> = {
  'a side-effect import before a named import': {
    'main.mjs': "import './a.mjs';\nimport { b } from './b.mjs';\nconsole.log('main', b);",
    'a.mjs': a,
    'b.mjs': "console.log('b1');\nexport const b = 1;",
  },
  'a module reached through export star': {
    'main.mjs': "import './a.mjs';\nimport { z } from './r.mjs';\nconsole.log('r', z);",
    'a.mjs': a,
    'r.mjs': "export * from './z.mjs';",
    'z.mjs': "console.log('z');\nexport const z = 1;",
  },
  'a named re-export': {
    'main.mjs': "import './a.mjs';\nimport { z } from './r.mjs';\nconsole.log('r', z);",
    'a.mjs': a,
    'r.mjs': "export { z } from './z.mjs';",
    'z.mjs': "console.log('z');\nexport const z = 1;",
  },
  'a CommonJS dependency after the awaited module': {
    'main.mjs': "import './a.mjs';\nimport { b } from './b.mjs';\nconsole.log('main', b);",
    'a.mjs': a,
    'b.mjs': "import c from './c.cjs';\nconsole.log('b1', c);\nexport const b = 1;",
    'c.cjs': "console.log('c');\nmodule.exports = 2;",
  },
  'a dynamically imported module with top-level await': {
    'main.mjs': "const m = await import('./d.mjs');\nconsole.log('d', m.v);",
    'd.mjs': 'await 0;\nexport const v = 9;',
  },
};

describe('modules after a top-level await run after it (#5662)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const bundle = async (dir: string, target: string, minify: boolean) => {
    const out = join(dir, `out-${target}${minify ? '-min' : ''}.mjs`);
    const result = await runZntc([
      '--bundle',
      join(dir, 'main.mjs'),
      '--format=esm',
      `--target=${target}`,
      ...(minify ? ['--minify'] : []),
      '-o',
      out,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    const run = spawnSync('node', [out], { encoding: 'utf8' });
    expect(run.status, run.stderr).toBe(0);
    return run.stdout;
  };

  for (const [name, files] of Object.entries(cases)) {
    for (const target of ['es2021', 'es2020', 'es2017']) {
      for (const minify of [false, true]) {
        test(`${name}, ${target}${minify ? ', minify' : ''}`, async () => {
          const created = await createFixture(files);
          cleanup = created.cleanup;
          const reference = await bundle(created.dir, 'es2022', false);
          expect(await bundle(created.dir, target, minify)).toBe(reference);
        });
      }
    }
  }
});
