import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// Code splitting binds a cross-chunk import to a top-level name in the
// consuming chunk. That name must not capture a free global reference in the
// consumer (#5456), and an entry chunk that exports the symbol publicly under
// another name must still be importable (esbuild: `import { v as v2 }`).
const cases = [
  {
    name: 'cross-chunk import does not capture a same-named free global',
    files: {
      'a.js': `export function f() { return 'a'; }`,
      'b.js': `import { f as af } from './a.js';
        export const r = af() + ' ' + typeof f;`,
      'entry.js': `const { r } = await import('./b.js'); console.log(r); await import('./a.js');`,
    },
  },
  {
    name: 'same-named exports from two entry chunks keep their public names',
    files: {
      'a.js': `export const v = 'a';`,
      'b.js': `export const v = 'b';`,
      'c.js': `import { v } from './a.js'; import { v as w } from './b.js'; export const r = v + w;`,
      'entry.js': `const { r } = await import('./c.js'); console.log(r);
        console.log(Object.keys(await import('./a.js')).join(), Object.keys(await import('./b.js')).join());`,
    },
  },
] as const;

describe('code splitting cross-chunk import names (#5456)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const minify of [false, true]) {
      test(`${fixture.name}${minify ? ', minify' : ''}`, async () => {
        const created = await createFixture({
          ...fixture.files,
          'package.json': '{"type":"module"}',
        });
        cleanup = created.cleanup;
        const native = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);

        const outdir = join(created.dir, 'out');
        const result = await runZntc([
          '--bundle',
          join(created.dir, 'entry.js'),
          '--splitting',
          '--format=esm',
          ...(minify ? ['--minify'] : []),
          '--outdir',
          outdir,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        writeFileSync(join(outdir, 'package.json'), '{"type":"module"}');
        const run = spawnSync('node', [join(outdir, 'entry.js')], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(native.stdout);
      });
    }
  }
});
