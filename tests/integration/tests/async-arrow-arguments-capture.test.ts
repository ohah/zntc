import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cases = [
  {
    name: 'captures the outer arguments object without shadowing a user _arguments',
    source: `
      function read(a, b, _arguments) {
        return (async () => {
          await Promise.resolve();
          return [arguments.length, arguments[0], _arguments].join(':');
        })();
      }
      read(11, 22, 33).then(console.log);
    `,
    expected: '3:11:33\n',
    expectsSyntheticBinding: true,
  },
  {
    name: 'keeps the outer arguments binding through nested async arrows',
    source: `
      function read(a, b) {
        return (async () => {
          await Promise.resolve();
          return (async () => {
            await Promise.resolve();
            return arguments.length + ':' + arguments[0];
          })();
        })();
      }
      read(11, 22).then(console.log);
    `,
    expected: '2:11\n',
    expectsSyntheticBinding: true,
  },
  {
    name: 'leaves arguments in async arrow parameter defaults in the lexical environment',
    source: `
      function read(a, b) {
        return (async (count = arguments.length) => {
          await Promise.resolve();
          return count;
        })();
      }
      read(11, 22).then(console.log);
    `,
    expected: '2\n',
    expectsSyntheticBinding: false,
  },
  {
    name: 'preserves lexical new.target when the body moves into a generator',
    source: `
      function read() {
        return (async () => {
          await Promise.resolve();
          return new.target === read;
        })();
      }
      new read().then(console.log);
    `,
    expected: 'true\n',
    expectsSyntheticBinding: true,
  },
] as const;

describe('async arrow arguments capture (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const bundle of [false, true]) {
    for (const minifyIdentifiers of [false, true]) {
      for (const scenario of cases) {
        test(`${scenario.name}, ${bundle ? 'bundle' : 'single'}, ${minifyIdentifiers ? 'identifier-minified' : 'plain'}`, async () => {
          const fixture = await createFixture({
            'input.js': scenario.source,
            'package.json': '{"type":"commonjs"}',
          });
          cleanup = fixture.cleanup;

          const input = join(fixture.dir, 'input.js');
          const native = spawnSync('node', [input], { encoding: 'utf8' });
          expect(native.status, native.stderr).toBe(0);
          expect(native.stdout).toBe(scenario.expected);

          const output = join(fixture.dir, bundle ? 'out.cjs' : 'out.js');
          const result = spawnSync(
            ZNTC_BIN,
            [
              ...(bundle ? ['--bundle', input, '--platform=node', '--format=cjs'] : [input]),
              '--target=es2015',
              ...(minifyIdentifiers ? ['--minify-identifiers'] : []),
              '-o',
              output,
            ],
            {
              cwd: fixture.dir,
              env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
              encoding: 'utf8',
            },
          );
          expect(result.status, result.stderr).toBe(0);

          const auditPrefix = bundle ? 'zntc: symbol-identity-prepass ' : 'zntc: symbol-identity ';
          const report = (result.stderr ?? '')
            .split(/\r?\n/)
            .find((line) => line.startsWith(auditPrefix) && line.includes('input.js'));
          expect(report, result.stderr).toBeDefined();
          if (scenario.expectsSyntheticBinding)
            expect(report).toMatch(/generated_bindings=[1-9]\d*/);
          expect(report).toMatch(/generated_references=[1-9]\d*/);
          expect(report).toMatch(/missing_binding=0/);
          expect(report).toMatch(/missing_reference=0/);
          expect(report).toMatch(/unclassified_reference=0/);
          expect(report).toMatch(/clean=1(?:\s|$)/);

          const runtime = spawnSync('node', [output], { encoding: 'utf8' });
          expect(runtime.status, runtime.stderr).toBe(0);
          expect(runtime.stdout).toBe(native.stdout);
        });
      }
    }
  }
});
