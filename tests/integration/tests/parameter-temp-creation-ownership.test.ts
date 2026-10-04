import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { ZNTC_BIN, createFixture } from './helpers';

const cases = [
  {
    name: 'default object pattern',
    source: `
const _a = 701;
const _b = 809;
function run({ first: { seed } } = { first: { seed: 5 } }) {
  return seed + _a + _b;
}
console.log(JSON.stringify([run(), run({ first: { seed: 11 } })]));
`,
  },
  {
    name: 'default array pattern and defaulted element',
    source: `
const _a = 701;
const _b = 809;
function run([{ first: { seed } } = { first: { seed: 7 } }] = [{ first: { seed: 5 } }]) {
  return seed + _a + _b;
}
console.log(JSON.stringify([run(), run([undefined]), run([{ first: { seed: 11 } }])]));
`,
  },
  {
    name: 'plain object pattern',
    source: `
const _a = 701;
const _b = 809;
function run({ first: { seed } }) {
  return seed + _a + _b;
}
console.log(JSON.stringify([run({ first: { seed: 5 } }), run({ first: { seed: 11 } })]));
`,
  },
  {
    name: 'plain array pattern',
    source: `
const _a = 701;
const _b = 809;
function run([{ first: { seed } }]) {
  return seed + _a + _b;
}
console.log(JSON.stringify([run([{ first: { seed: 5 } }]), run([{ first: { seed: 11 } }])]));
`,
  },
] as const;

describe('parameter destructuring temp creation ownership (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const bundle of [false, true]) {
      test(`${fixture.name}, ${bundle ? 'bundle' : 'standalone'}`, async () => {
        const dir = await createFixture({
          'input.mjs': fixture.source,
          'package.json': '{"type":"module"}',
        });
        cleanup = dir.cleanup;

        const input = join(dir.dir, 'input.mjs');
        const native = spawnSync('node', [input], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);

        const output = join(dir.dir, bundle ? 'out.cjs' : 'out.mjs');
        const compiled = spawnSync(
          ZNTC_BIN,
          [
            ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
            'input.mjs',
            '--target=es5',
            '-o',
            output,
          ],
          {
            cwd: dir.dir,
            env: {
              ...process.env,
              ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
              ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
            },
            encoding: 'utf8',
          },
        );
        expect(compiled.status, compiled.stderr).toBe(0);
        const identityReports = compiled.stderr
          .split(/\r?\n/)
          .filter((line) => /^zntc: symbol-identity(?:-prepass)? /.test(line));
        expect(identityReports.length, compiled.stderr).toBeGreaterThan(0);
        for (const report of identityReports) expect(report).toMatch(/clean=1(?:\s|$)/);

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(0);
        expect(actual.stdout).toBe(native.stdout);
      });
    }
  }
});
