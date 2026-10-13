import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

// #5677: with assign semantics and native private names (es2022+), a private
// instance field moves to the constructor as `this.#p = …` while its `#p;`
// declaration stays in the class. Both used one `#p` key node, which the
// symbol gate reports as one AST node with two parents (`ambiguous_ast_parent`).
const cases: Record<string, { source: string; args: string[]; expected: string }> = {
  'a computed field next to a private field': {
    source:
      'const k = "k1";\nclass C { #p = 1; [k] = 1; get p() { return this.#p; } }\nconsole.log(Object.keys(new C()).join(), new C().p);\n',
    args: ['--use-define-for-class-fields=false'],
    expected: 'k1 1\n',
  },
  'a legacy class decorator with a private field': {
    source:
      'const log = [];\nfunction dec(c) { log.push(typeof c); }\n@dec class A { #x = 1; get x() { return this.#x; } }\nconsole.log(new A().x, log.join());\n',
    args: ['--experimental-decorators'],
    expected: '1 function\n',
  },
};

describe('assign-semantics private field key nodes (#5677)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, { source, args, expected }] of Object.entries(cases)) {
    for (const target of ['es2022', 'esnext']) {
      for (const extra of [[], ['--minify']]) {
        test(`${name}, ${target} ${extra.join(' ')}`, async () => {
          const created = await createFixture({ 'input.ts': source });
          cleanup = created.cleanup;
          const out = join(created.dir, 'out.cjs');
          const proc = spawnSync(
            ZNTC_BIN,
            ['input.ts', `--target=${target}`, ...args, ...extra, '-o', out],
            {
              cwd: created.dir,
              env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
              encoding: 'utf8',
            },
          );
          expect(proc.status, proc.stderr).toBe(0);
          const report = (proc.stderr ?? '')
            .split(/\r?\n/)
            .find((line) => line.startsWith('zntc: symbol-identity ') && line.includes('input.ts'));
          expect(report, proc.stderr).toMatch(/ambiguous_ast_parent=0(?:\s|$)/);
          expect(report, proc.stderr).toMatch(/clean=1(?:\s|$)/);
          const run = spawnSync('node', [out], { encoding: 'utf8' });
          expect(run.status, run.stderr).toBe(0);
          expect(run.stdout).toBe(expected);
        });
      }
    }
  }
});
