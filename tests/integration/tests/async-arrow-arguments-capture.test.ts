import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cases = [
  {
    name: 'captures the outer arguments object without shadowing a user _arguments',
    source: `
      function read(a, b, _arguments) {
        const outer = _arguments;
        return (async () => {
          const _arguments = 99;
          await Promise.resolve();
          return [arguments.length, arguments[0], _arguments, outer].join(':');
        })();
      }
      read(11, 22, 33).then(console.log);
    `,
    expected: '3:11:99:33\n',
    expectsSyntheticBinding: true,
    expectsRetainedGraph: true,
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
    expectsRetainedGraph: true,
  },
  {
    name: 'captures an explicit arguments parameter by its source binding',
    inputFile: 'input.cjs',
    source: `
      function read(arguments) {
        return (async () => {
          await Promise.resolve();
          return arguments;
        })();
      }
      read(42).then(console.log);
    `,
    expected: '42\n',
    expectsSyntheticBinding: true,
    expectsRetainedGraph: true,
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
    expectsRetainedGraph: true,
  },
  {
    name: 'does not capture arguments owned by a nested ordinary function',
    source: `
      function read() {
        return (async () => {
          await Promise.resolve();
          function nested(first, second) {
            return arguments.length + ':' + arguments[0];
          }
          return nested(21, 34);
        })();
      }
      read().then(console.log);
    `,
    expected: '2:21\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains lexical new.target through nested async arrows and collisions',
    source: `
      function read(_newTarget) {
        const outer = _newTarget;
        return (async () => {
          const _newTarget = 99;
          await Promise.resolve();
          return (async () => {
            await Promise.resolve();
            return [new.target === read, _newTarget, outer].join(':');
          })();
        })();
      }
      new read(7).then(console.log);
    `,
    expected: 'true:99:7\n',
    expectsSyntheticBinding: true,
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'retains lexical this capture identity through _this name collisions',
    source: `
      function read(_this) {
        const outer = _this;
        return (async () => {
          const _this = 99;
          await Promise.resolve();
          return [this.value, _this, outer].join(':');
        })();
      }
      read.call({ value: 42 }, 7).then(console.log);
    `,
    expected: '42:99:7\n',
    expectsSyntheticBinding: false,
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'shares lexical this capture through nested async arrows',
    source: `
      function read() {
        return (async () => {
          await Promise.resolve();
          return (async () => {
            await Promise.resolve();
            return this.value;
          })();
        })();
      }
      read.call({ value: 42 }).then(console.log);
    `,
    expected: '42\n',
    expectsSyntheticBinding: false,
    expectsBundleSyntheticBinding: true,
    expectsRetainedGraph: true,
  },
  {
    name: 'keeps direct eval on the conservative graph path',
    source: `
      function read() {
        return (async () => {
          await Promise.resolve();
          return eval('40 + 2');
        })();
      }
      read().then(console.log);
    `,
    expected: '42\n',
    expectsSyntheticBinding: false,
    expectsRetainedGraph: false,
    expectsCleanIdentity: false,
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
          const inputFile = scenario.inputFile ?? 'input.js';
          const fixture = await createFixture({
            [inputFile]: scenario.source,
            'package.json': '{"type":"commonjs"}',
          });
          cleanup = fixture.cleanup;

          const input = join(fixture.dir, inputFile);
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

          if (bundle) {
            const mode = (result.stderr ?? '')
              .split(/\r?\n/)
              .find(
                (line) =>
                  line.startsWith('zntc: symbol-identity-prepass-mode ') &&
                  line.includes(inputFile),
              );
            expect(mode, result.stderr).toBeDefined();
            expect(mode).toContain(
              scenario.expectsRetainedGraph
                ? 'semantic_graph=retained'
                : 'semantic_graph=reanalyzed',
            );
          }

          const auditPrefix = bundle ? 'zntc: symbol-identity-prepass ' : 'zntc: symbol-identity ';
          const report = (result.stderr ?? '')
            .split(/\r?\n/)
            .find((line) => line.startsWith(auditPrefix) && line.includes(inputFile));
          expect(report, result.stderr).toBeDefined();
          if (scenario.expectsSyntheticBinding)
            expect(report).toMatch(/generated_bindings=[1-9]\d*/);
          if (bundle && scenario.expectsBundleSyntheticBinding)
            expect(report).toMatch(/generated_bindings=[1-9]\d*/);
          expect(report).toMatch(/generated_references=[1-9]\d*/);
          if (scenario.expectsCleanIdentity !== false) {
            expect(report).toMatch(/missing_binding=0/);
            expect(report).toMatch(/missing_reference=0/);
            expect(report).toMatch(/unclassified_reference=0/);
            expect(report).toMatch(/clean=1(?:\s|$)/);
          }

          const runtime = spawnSync('node', [output], { encoding: 'utf8' });
          expect(runtime.status, runtime.stderr).toBe(0);
          expect(runtime.stdout).toBe(native.stdout);
        });
      }
    }
  }
});
