import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const writes = [
  "eval('value=9');",
  "function mutate(){eval('value=9')}mutate();",
  "(()=>eval('value=9'))();",
  "({mutate(){eval('value=9')}}).mutate();",
  "const code='value=9';eval(code);",
  "eval('value+=7');",
  "eval('value++');",
  "eval('[value]=[9]');",
  "for(let i=0;i<1;i++)eval('value=9');",
  "function mutate(n){if(n)mutate(n-1);else eval('value=9')}mutate(1);",
];
const modes = [[], ['--minify-identifiers'], ['--minify-syntax', '--minify-identifiers']];

describe('mutable export constant facts respect provider dynamic scope (#4819)', () => {
  for (const [index, write] of writes.entries()) {
    for (const kind of ['let', 'var']) {
      for (const target of ['es2015', 'es5']) {
        for (const split of [false, true]) {
          for (const mode of modes) {
            test(`write ${index}, ${kind}, ${target}, split=${split}, ${mode.join('+') || 'plain'}`, async () => {
              const fixture = await createFixture({
                'package.json': '{"type":"module"}',
                'seed.mjs': 'export const base=1;',
                'provider.mjs': `import {base} from './seed.mjs';export ${kind} value=base+1;${write}`,
                'barrel.mjs': "export {value as answer} from './provider.mjs';",
                'entry.mjs': "import {answer} from './barrel.mjs';console.log(answer);",
                'second.mjs': "import {answer} from './barrel.mjs';console.log(answer);",
              });
              try {
                const expected = spawnSync('node', [join(fixture.dir, 'entry.mjs')], {
                  encoding: 'utf8',
                });
                expect(expected.status, expected.stderr).toBe(0);
                const args = [
                  'entry.mjs',
                  '--bundle',
                  '--format=esm',
                  `--target=${target}`,
                  ...mode,
                ];
                if (split) args.push('second.mjs', '--splitting', '--outdir', 'out');
                else args.push('-o', 'output.mjs');
                const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
                expect(built.status, built.stderr).toBe(0);
                const output = join(fixture.dir, split ? 'out/entry.js' : 'output.mjs');
                const actual = spawnSync('node', [output], { encoding: 'utf8' });
                expect(actual.status, actual.stderr).toBe(0);
                expect(actual.stdout).toBe(expected.stdout);
              } finally {
                await fixture.cleanup();
              }
            });
          }
        }
      }
    }
  }
});
