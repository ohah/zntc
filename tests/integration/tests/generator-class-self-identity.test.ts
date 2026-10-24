import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const prelude =
  'function Base() { this.value = 41; } Base.prototype.read = function() { return this.value; };';
const cases = [
  [
    'await heritage',
    'async function run() { class D extends (await Promise.resolve(Base)) { read() { return super.read() + 1; } } return new D().read(); } run().then(console.log);',
  ],
  [
    'yield heritage',
    'function* run() { class D extends (yield Base) { read() { return super.read() + 1; } } return new D().read(); } var g = run(); var first = g.next(); console.log(g.next(first.value).value);',
  ],
  [
    'await computed method',
    'async function run() { class D { [await Promise.resolve("read")]() { return 42; } } return new D().read(); } run().then(console.log);',
  ],
  [
    'yield computed method',
    'function* run() { class D { [yield "read"]() { return 42; } } return new D().read(); } var g = run(); var first = g.next(); console.log(g.next(first.value).value);',
  ],
  [
    'heritage and computed method',
    'async function run() { class D extends (await Promise.resolve(Base)) { [await Promise.resolve("read")]() { return super.read() + 1; } } return new D().read(); } run().then(console.log);',
  ],
  [
    'nested function',
    'function outer() { return async function run() { class D extends (await Promise.resolve(Base)) { read() { return super.read() + 1; } } return new D().read(); }; } outer()().then(console.log);',
  ],
  [
    'outer spelling decoy',
    'var D = 100; async function run() { class D extends (await Promise.resolve(Base)) { read() { return super.read() + 1; } } return new D().read(); } run().then(value => console.log(value + D - 100));',
  ],
  [
    'two class declarations',
    'async function run() { class First extends (await Promise.resolve(Base)) {} class Second extends (await Promise.resolve(First)) { read() { return super.read() + 1; } } return new Second().read(); } run().then(console.log);',
  ],
  [
    'same spelling in blocks',
    'async function run() { var value; { class D extends (await Promise.resolve(Base)) {} value = new D().read(); } { class D extends (await Promise.resolve(Base)) {} return value + new D().read() - 40; } } run().then(console.log);',
  ],
  [
    'async generator',
    'async function* run() { class D extends (yield await Promise.resolve(Base)) { read() { return super.read() + 1; } } return new D().read(); } var g = run(); g.next().then(first => g.next(first.value)).then(last => console.log(last.value));',
  ],
] as const;

describe('copied generator class self identities (#4819)', () => {
  for (const [name, source] of cases) {
    for (const minify of [false, true]) {
      test(`${name}, minify=${minify}`, async () => {
        const fixture = await createFixture({ 'input.ts': `${prelude}\n${source}` });
        try {
          const output = join(fixture.dir, 'out.cjs');
          const args = ['input.ts', '--target=es5', '-o', output];
          if (minify) args.push('--minify-identifiers');
          const built = spawnSync(ZNTC_BIN, args, {
            cwd: fixture.dir,
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
            encoding: 'utf8',
          });
          expect(built.status, built.stderr).toBe(0);
          const identity = built.stderr
            .split(/\r?\n/)
            .find((line) => line.startsWith('zntc: symbol-identity '));
          expect(identity, built.stderr).toMatch(/clean=1(?:\s|$)/);
          if (minify) {
            const renamed = built.stderr
              .split(/\r?\n/)
              .find((line) => line.startsWith('zntc: symbol-identity-post-minify '));
            expect(renamed, built.stderr).toMatch(/clean=1(?:\s|$)/);
          }
          const runtime = spawnSync('node', [output], { encoding: 'utf8' });
          expect(runtime.status, runtime.stderr).toBe(0);
          expect(runtime.stdout).toBe('42\n');
        } finally {
          await fixture.cleanup();
        }
      });
    }
  }
});
