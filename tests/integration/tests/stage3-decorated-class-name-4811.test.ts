import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

// #4811: names of Stage 3 decorated classes.
//  - `export default @d class Named {}` parsed as a class expression, so the
//    module never bound `Named` (ReferenceError);
//  - `const Anon = @d class {}` was named `_Class`;
//  - lowered to es2015/es5, a decorated named class (or one with decorated
//    members only) was named after its generated binding (`_a`, `_Class`).
// Expected values are tsc's output run in Node. The symbol gate must stay
// clean: `export default Named` reads the hoisted declaration.
const source = `function logged(v: any, ctx: any) { return v; }
export default @logged class Named {}
const Anon = @logged class {};
@logged class Foo {}
class Plain { @logged m() {} }
console.log(Named.name, Anon.name, Foo.name, Plain.name);
`;

describe('Stage 3 decorated class names (#4811)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['esnext', 'es2022', 'es2015', 'es5']) {
    for (const extra of [[], ['--minify']]) {
      test(`${target} ${extra.join(' ')}`, async () => {
        const created = await createFixture({ 'input.mts': source });
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.mjs');
        const proc = spawnSync(ZNTC_BIN, ['input.mts', `--target=${target}`, ...extra, '-o', out], {
          cwd: created.dir,
          env:
            extra.length === 0 ? { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } : process.env,
          encoding: 'utf8',
        });
        expect(proc.status, proc.stderr).toBe(0);
        // The post-minify gate has its own open debt on this input (#5757).
        if (extra.length === 0) {
          const report = (proc.stderr ?? '')
            .split(/\r?\n/)
            .find(
              (line) => line.startsWith('zntc: symbol-identity ') && line.includes('input.mts'),
            );
          expect(report, proc.stderr).toMatch(/clean=1(?:\s|$)/);
        }
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe('Named Anon Foo Plain\n');
      });
    }
  }
});
