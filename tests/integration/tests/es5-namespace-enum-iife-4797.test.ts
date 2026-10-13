import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4797: at --target=es5 the TS namespace and enum IIFEs, which the codegen
// writes itself, still came out as arrow functions (`((N) => {…})(N || …)`),
// a syntax error for an ES5 engine. Node ran them, so a run alone did not
// catch it: the output must hold no `=>`.
const files: Record<string, string> = {
  'm.ts':
    'export namespace NS { export const v = 1; export namespace Inner { export const y = 2; } }\nexport enum EE { Q, R = "r" }\n',
  'entry.ts':
    "import { NS, EE } from './m.ts';\nnamespace Local { export const x = 3; }\nenum E { A }\nconsole.log(NS.v, NS.Inner.y, EE.Q, EE.R, Local.x, E.A);\n",
};

describe('ES5 namespace and enum IIFEs use function expressions (#4797)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const args of [
    [],
    ['--minify'],
    ['--bundle'],
    ['--bundle', '--minify'],
    ['--bundle', '--format=iife'],
    ['--bundle', '--platform=react-native'],
  ]) {
    test(args.join(' ') || 'transpile', async () => {
      const created = await createFixture(files);
      cleanup = created.cleanup;
      const out = join(created.dir, 'out.js');
      const input = join(created.dir, args.includes('--bundle') ? 'entry.ts' : 'm.ts');
      const result = await runZntc([input, '--target=es5', ...args, '-o', out]);
      expect(result.exitCode, result.stderr).toBe(0);
      expect(readFileSync(out, 'utf8')).not.toContain('=>');
      if (args.includes('--bundle')) {
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe('1 2 0 r 3 0\n');
      }
    });
  }
});
