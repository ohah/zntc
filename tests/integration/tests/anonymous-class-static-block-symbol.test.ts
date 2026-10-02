import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createFixture, runZntcInDir } from './helpers';

const source = readFileSync(
  join(import.meta.dir, '../fixtures/downlevel-oracle/4819-anonymous-class-static-block-id.mjs'),
  'utf8',
);

describe('anonymous class static-block SymbolIds (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const bundle of [false, true]) {
    for (const minify of [false, true]) {
      test(`${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
        const fixture = await createFixture({
          'input.mjs': source,
          'package.json': '{"type":"module"}',
        });
        cleanup = fixture.cleanup;
        const output = join(fixture.dir, 'out.mjs');
        const build = await runZntcInDir(fixture.dir, [
          ...(bundle ? ['--bundle', '--platform=node', '--format=esm'] : []),
          'input.mjs',
          '--target=es5',
          ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
          '-o',
          output,
        ]);
        expect(build.exitCode, build.stderr).toBe(0);

        const runtime = spawnSync(
          'node',
          [
            '--input-type=module',
            '-e',
            `globalThis.__zntcAnonymousClassSelfs = []; await import(process.argv[1]); console.log(JSON.stringify(globalThis.__zntcAnonymousClassSelfs.map((klass) => [typeof klass, klass.readValue()])));`,
            pathToFileURL(output).href,
          ],
          { encoding: 'utf8' },
        );
        expect(runtime.status, runtime.stderr).toBe(0);
        expect(runtime.stdout.trim().split('\n')).toEqual([
          'outer,10,20,parameter',
          '[["function",10],["function",20]]',
        ]);
      });
    }
  }
});
