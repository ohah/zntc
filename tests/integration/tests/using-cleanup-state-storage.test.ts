import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cases = [
  [
    'block before await',
    "{ using resource = make('a'); events.push(resource.label); } await null; return 'done';",
  ],
  [
    'multiple declarators',
    "{ using first = make('a'), second = make('b'); events.push(first.label + second.label); } await null;",
  ],
  [
    'nested resources',
    "{ using outer = make('a'); { using inner = make('b'); events.push(outer.label + inner.label); } } await null;",
  ],
  [
    'iteration closure capture',
    'for (let index = 0; index < 2; index++) { { using resource = make(String(index)); readers.push(() => resource.label); } await null; } return readers.map(read => read());',
  ],
  [
    'var survives callback reentry',
    "{ using resource = make('a'); var shared = resource.label; } await null; return shared;",
  ],
  [
    'body suspension',
    "{ using resource = make('a'); await null; events.push(resource.label); } return 'done';",
  ],
  [
    'initializer suspension',
    "{ using resource = await Promise.resolve(make('a')); events.push(resource.label); } await null;",
  ],
  [
    'async disposal',
    "{ await using resource = make('a'); events.push(resource.label); } return 'done';",
  ],
  ['return disposes first', "{ using resource = make('a'); return resource.label; }"],
  [
    'body and disposal throw',
    "{ using resource = make('a', true); events.push('body'); throw new Error('body'); }",
  ],
  [
    'top-level generator cleanup',
    "function* sequence() { using resource = make('a'); events.push(resource.label); } return [...sequence()];",
  ],
  [
    'initializer throws after first resource',
    "try { using first = make('a'), second = fail(); events.push(first.label + second.label); } catch (error) { events.push(error.message); } await null; return 'done';",
  ],
] as const;
const modes = [[], ['--minify-identifiers'], ['--minify-syntax', '--minify-identifiers']];
const targets = ['--target=es5', '--platform=react-native'];

describe('generated using cleanup state storage (#4819)', () => {
  for (const [name, body] of cases) {
    for (const target of targets) {
      for (const bundle of [false, true]) {
        for (const mode of modes) {
          test(`${name}, ${target}, bundle=${bundle}, ${mode.join('+') || 'plain'}`, async () => {
            const source = `
const events = [], readers = [];
const _using = 'outer-using', _stack = 'outer-stack', _error = 'outer-error', _hasError = 'outer-flag';
function make(label, fails = false) {
  events.push('init:' + label);
  return { label,
    [Symbol.dispose]() { events.push('dispose:' + label); if (fails) throw new Error('dispose:' + label); },
    [Symbol.asyncDispose]() { return Promise.resolve().then(() => events.push('async-dispose:' + label)); }
  };
}
function fail() { throw new Error('initializer'); }
async function main() { ${body} }
function print(result) { console.log(JSON.stringify({ result, events, outside: [_using, _stack, _error, _hasError] })); }
main().then(value => print({value}), error => print({name:error.name, error:error.error && error.error.message, suppressed:error.suppressed && error.suppressed.message}));
`;
            const fixture = await createFixture({ 'input.mjs': source });
            try {
              const reference = spawnSync('node', [join(fixture.dir, 'input.mjs')], {
                encoding: 'utf8',
              });
              expect(reference.status, reference.stderr).toBe(0);
              const output = join(fixture.dir, 'output.cjs');
              const args = ['input.mjs', target, ...mode, '-o', output];
              if (bundle) args.push('--bundle', '--format=cjs');
              const built = spawnSync(ZNTC_BIN, args, {
                cwd: fixture.dir,
                env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
                encoding: 'utf8',
              });
              expect(built.status, built.stderr).toBe(0);
              const prefix = bundle ? 'zntc: symbol-identity-prepass ' : 'zntc: symbol-identity ';
              const report = built.stderr
                .split(/\r?\n/)
                .find((line) => line.startsWith(prefix) && line.includes('input.mjs:'));
              expect(report, built.stderr).toMatch(/clean=1(?:\s|$)/);
              if (!bundle && mode.includes('--minify-identifiers')) {
                const renamed = built.stderr
                  .split(/\r?\n/)
                  .find((line) => line.startsWith('zntc: symbol-identity-post-minify '));
                expect(renamed, built.stderr).toMatch(/clean=1(?:\s|$)/);
              }
              const actual = spawnSync('node', [output], { encoding: 'utf8' });
              expect(actual.status, actual.stderr).toBe(0);
              expect(actual.stdout).toBe(reference.stdout);
            } finally {
              await fixture.cleanup();
            }
          });
        }
      }
    }
  }
});
