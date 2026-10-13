import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5669: a class with a decorated `accessor` or private field, lowered to
// es2015~es2021, kept raw `#storage` syntax (`codegen.zig` assertion, or
// a SyntaxError). Stage 3 decorator output was lowered again only for ES5;
// other targets now run the class lowering over it too. The synthetic private
// storage name also lived in `string_table` and dangled after later
// `addString` calls, so private lowering missed it in safe builds. Expected
// output is tsc's (ES2022 decorator lowering).
const source =
  "const log = [];\nfunction wrapAcc(target, ctx) {\n  log.push(ctx.kind + ':' + ctx.name);\n  return { get() { return target.get.call(this) * 10; }, set(v) { target.set.call(this, v + 1); }, init(v) { return v + 100; } };\n}\nfunction getOnly(target, ctx) { log.push(ctx.kind + \":\" + ctx.name); return { get() { return target.get.call(this) * 10; } }; }\nfunction field(_, ctx) { log.push(ctx.kind + ':' + ctx.name); return (v) => v * 2; }\nfunction priv(_, ctx) { log.push(ctx.kind + ':' + ctx.name); ctx.addInitializer(function () { log.push('init:' + ctx.access.get(this)); }); }\nclass A {\n  @wrapAcc accessor a = 1;\n  @getOnly static accessor s = 2;\n  @priv #x = 7;\n  @field y = 3;\n  m() { return this.#x; }\n}\nconst o = new A();\no.a = 5;\nconsole.log(log.join(), o.a, A.s, o.m(), o.y);\n";
const expected = 'accessor:s,accessor:a,field:#x,field:y,init:7 60 20 7 6\n';

describe('decorated accessors and private fields below es2022 (#5669)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['esnext', 'es2022', 'es2021', 'es2015', 'es5']) {
    for (const mode of ['transform', 'minify', 'bundle']) {
      test(`${target}, ${mode}`, async () => {
        const created = await createFixture({ 'entry.js': source });
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.js');
        const args = mode === 'bundle' ? ['--bundle'] : mode === 'minify' ? ['--minify'] : [];
        const result = await runZntc([
          ...args,
          join(created.dir, 'entry.js'),
          `--target=${target}`,
          '-o',
          out,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected);
      });
    }
  }
});
