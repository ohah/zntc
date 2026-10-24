import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const bodies = [
  'use(value);',
  '{ if (value === 2) continue outer; use(value); }',
  '{ use(value); if (value === 2) break outer; }',
  '{ try { use(value); } finally { use("finally"); } }',
  '{ for (const inner of [0, 1]) use(value + inner); }',
  '{ const read = () => value; use(read()); }',
  '{ function* nested() { yield value; } use(nested().next().value); }',
  '{ function nested() { return value; } use(nested()); }',
  '{ switch (value) { case 1: break; default: use(value); } }',
  '{ let copy = value; while (copy--) use(copy); }',
  // These paths keep iterator storage in the wrapper across suspension/return.
  '{ yield value; }',
  "{ if (value === 2) return 'stopped'; use(value); }",
];
const modes = [[], ['--minify-identifiers'], ['--minify-syntax', '--minify-identifiers']];

describe('native state-machine loop temp identity (#4819)', () => {
  for (const [index, body] of bodies.entries()) {
    for (const mode of modes) {
      test(`loop body ${index}, ${mode.join('+') || 'plain'}`, async () => {
        const source = `
const events = [];
const _d = 'outer-iterator', _step = 'outer-step';
function use(value) { events.push(value); }
function* iterable() { try { yield 1; yield 2; yield 3; } finally { use('closed'); } }
function* run() { outer: for (const value of iterable()) ${body} yield [_d, _step].join('|'); }
console.log(JSON.stringify({ values: [...run()], events }));
`;
        const fixture = await createFixture({ 'input.mjs': source });
        try {
          const expected = spawnSync('node', [join(fixture.dir, 'input.mjs')], {
            encoding: 'utf8',
          });
          expect(expected.status, expected.stderr).toBe(0);
          const output = join(fixture.dir, 'out.mjs');
          const built = spawnSync(ZNTC_BIN, ['input.mjs', '--target=es5', ...mode, '-o', output], {
            cwd: fixture.dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          });
          expect(built.status, built.stderr).toBe(0);
          const report = built.stderr
            .split(/\r?\n/)
            .find((line) => line.startsWith('zntc: symbol-identity '));
          expect(report, built.stderr).toMatch(/clean=1(?:\s|$)/);
          if (mode.includes('--minify-identifiers')) {
            const renamed = built.stderr
              .split(/\r?\n/)
              .find((line) => line.startsWith('zntc: symbol-identity-post-minify '));
            expect(renamed, built.stderr).toMatch(/clean=1(?:\s|$)/);
          }
          const runtime = spawnSync('node', [output], { encoding: 'utf8' });
          expect(runtime.status, runtime.stderr).toBe(0);
          expect(runtime.stdout).toBe(expected.stdout);
        } finally {
          await fixture.cleanup();
        }
      });
    }
  }
});
