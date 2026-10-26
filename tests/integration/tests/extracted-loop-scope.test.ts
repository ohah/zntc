import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, runZntc } from './helpers';

const cases = [
  {
    name: 'shadowed parameters, copied references and control flow',
    extension: 'mjs',
    source: `
const _loop = 40, _ret = 50;
function collect(limit) {
  const readers = [];
  let index = 100;
  for (let index = 0, offset = 3; index < limit; index++, offset--) {
    var last = index;
    let copied = index ?? 9;
    const object = {[index]: copied, index};
    readers.push(function () { return index + offset + copied + object[index] + _loop; });
    { let index = 7; readers.push(() => index); }
    if (index === 1) continue;
    if (index === 2) break;
  }
  return [readers.map(read => read()).join(','), index, last, _ret].join('|');
}
console.log(collect(4));
`,
  },
  {
    name: 'generator extracted loop preserves shadowed header and yielded closure owners',
    extension: 'mjs',
    source: readFileSync(
      join(import.meta.dir, '../fixtures/downlevel-oracle/4819-generator-shadowed-loop-header.mjs'),
      'utf8',
    ),
  },
  {
    name: 'unbraced bodies and nested extracted loops',
    extension: 'mjs',
    source: `
const readers = [];
for (let index = 0; index < 2; index++) readers.push(() => index);
for (const key in {a: 1, b: 2}) readers.push(function () { return key; });
for (const value of [3, 4]) {
  for (let index = 0; index < 2; index++) readers.push(() => value + index);
}
let count = 0;
while (count < 2) {
  let captured = count++;
  readers.push(() => captured);
}
do {
  let captured = count++;
  readers.push(function () { return captured; });
} while (count < 4);
console.log(readers.map(read => read()).join(','));
`,
  },
  {
    name: 'sloppy Annex B loop functions preserve lexical and variable bindings',
    extension: 'cjs',
    source: `
function collect() {
  const readers = [];
  for (let index = 0; index < 2; index++) {
    function local() { return index; }
    readers.push(local);
  }
  return [local(), readers.map(read => read()).join(',')].join('|');
}
console.log(collect());
`,
  },
  {
    name: 'sloppy Annex B conditional declaration skipped by control flow',
    extension: 'cjs',
    source: `
function conditional() {
  for (let index = 0; index < 2; index++) {
    if (false && index === 1) {
      function later() { return index; }
    }
  }
  return typeof later;
}
console.log(conditional());
`,
  },
  {
    name: 'sloppy Annex B conditional declaration executes and captures the final iteration',
    extension: 'cjs',
    source: `
function conditional() {
  for (let index = 0; index < 2; index++) {
    if (index === 1) {
      function later() { return index; }
    }
  }
  return later();
}
console.log(conditional());
`,
  },
  {
    name: 'sloppy Annex B same-name branches update one variable binding',
    extension: 'cjs',
    source: `
function alternatives() {
  const readers = [];
  for (let index = 0; index < 2; index++) {
    if (index === 0) {
      function choose() { return 'a' + index; }
      readers.push(choose);
    } else {
      function choose() { return 'b' + index; }
      readers.push(choose);
    }
  }
  return [choose(), readers.map(read => read()).join(',')].join('|');
}
console.log(alternatives());
`,
  },
  {
    name: 'sloppy Annex B reuses an explicit var binding',
    extension: 'cjs',
    source: `
function explicitVar() {
  var shared;
  for (let index = 0; index < 2; index++) {
    function shared() { return index; }
  }
  return shared();
}
console.log(explicitVar());
`,
  },
  {
    name: 'sloppy Annex B reuses an explicit function binding',
    extension: 'cjs',
    source: `
function explicitFunction() {
  function shared() { return -1; }
  for (let index = 0; index < 2; index++) {
    function shared() { return index; }
  }
  return shared();
}
console.log(explicitFunction());
`,
  },
  {
    name: 'sloppy Annex B declares variable storage when the loop never runs',
    extension: 'cjs',
    source: `
function noIteration() {
  for (let index = 0; index < 0; index++) {
    function never() { return index; }
  }
  return typeof never;
}
console.log(noIteration());
`,
  },
  {
    name: 'sloppy Annex B at the program scope keeps the last loop binding',
    extension: 'cjs',
    source: `
for (let index = 0; index < 2; index++) {
  function topLevel() { return index; }
}
console.log(topLevel());
`,
  },
  {
    name: 'sloppy Annex B assignment runs at the declaration statement',
    extension: 'cjs',
    source: `
function ordering() {
  let before;
  const readOuter = () => local;
  for (let index = 0; index < 1; index++) {
    before = typeof readOuter();
    function local() { return index; }
  }
  return [before, typeof local].join('|');
}
console.log(ordering());
`,
  },
  {
    name: 'sloppy Annex B implicit var storage does not leak to the global object',
    extension: 'cjs',
    source: `
function noGlobalLeak() {
  for (let index = 0; index < 1; index++) {
    function local() { return index; }
  }
  return Object.prototype.hasOwnProperty.call(globalThis, 'local');
}
console.log(noGlobalLeak());
`,
  },
  {
    name: 'sloppy Annex B setter names stay hidden from direct eval',
    extension: 'cjs',
    source: `
function collect() {
  const visible = eval('typeof __zntc_annexb_set');
  for (let index = 0; index < 1; index++) {
    function local() { return index; }
  }
  return visible;
}
console.log(collect());
`,
  },
  {
    name: 'strict loop block functions do not create Annex B variable bindings',
    extension: 'mjs',
    source: `
function strictLoop() {
  const readers = [];
  for (let index = 0; index < 2; index++) {
    function local() { return index; }
    readers.push(local);
  }
  return [typeof local, readers.map(read => read()).join(',')].join('|');
}
console.log(strictLoop());
`,
  },
  {
    name: 'direct eval keeps the source-visible loop spelling reserved',
    extension: 'mjs',
    source: `
function collect() {
  const readers = [];
  for (let index = 0; index < 2; index++) {
    readers.push(() => [index, eval('typeof _loop2')].join(':'));
  }
  for (let index = 0; index < 2; index++) {
    readers.push(() => [index, eval('typeof _loop2')].join(':'));
  }
  return readers.map(read => read()).join('|');
}
console.log(collect());
`,
  },
  {
    name: 'control-flow result names use the final standalone symbol set',
    extension: 'mjs',
    source: `function run(_ret, _ret2) {
  const readers = [];
  for (let index = 0; index < 3; index++) {
    readers.push(() => index);
    if (index === 1) return readers.map((read) => read()).join(',');
  }
  return 'none';
}
console.log(run(10, 20));
`,
  },
  {
    name: 'escaped direct eval identifiers reserve early control-flow result names',
    extension: 'mjs',
    source: `function run() {
  const readers = [];
  for (let index = 0; index < 3; index++) {
    readers.push(() => index);
    if (index === 1) return [eval('typeof \\u005fret'), readers.map((read) => read()).join(',')].join(':');
  }
  return 'none';
}
console.log(run());
`,
  },
  {
    name: 'erased type references and nested function defaults',
    extension: 'ts',
    source: `
function collect() {
  const readers = [];
  for (let index = 0; index < 3; index++) {
    type Header = typeof index;
    const copied: Header = (index as number) ?? 9;
    readers.push(function read(value = index) { return value + copied; });
    try { throw index; } catch (index) {
      readers.push(() => index);
    }
  }
  return readers.map(read => read()).join(',');
}
console.log(collect());
`,
  },
] as const;

describe('extracted loop scopes (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixtureCase of cases) {
    for (const bundled of [false, true]) {
      for (const minify of [false, true]) {
        test(`${fixtureCase.name}: ${bundled ? 'bundle' : 'single-file'}, ${minify ? 'minify' : 'plain'}`, async () => {
          const inputName = `input.${fixtureCase.extension}`;
          const reference =
            fixtureCase.extension === 'ts'
              ? ts.transpileModule(fixtureCase.source, {
                  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext },
                }).outputText
              : fixtureCase.source;
          const referenceName = fixtureCase.extension === 'cjs' ? 'reference.cjs' : 'reference.mjs';
          const fixture = await createFixture({
            [inputName]: fixtureCase.source,
            [referenceName]: reference,
          });
          cleanup = fixture.cleanup;
          const native = spawnSync('node', [join(fixture.dir, referenceName)], {
            encoding: 'utf8',
          });
          expect(native.status).toBe(0);
          expect(native.stdout.trim().length).toBeGreaterThan(0);
          const out = join(fixture.dir, 'out.cjs');
          const result = await runZntc(
            [
              ...(bundled ? ['--bundle'] : []),
              join(fixture.dir, inputName),
              '--target=es5',
              ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
              ...(bundled ? ['--platform=node', '--format=cjs'] : []),
              '-o',
              out,
            ],
            { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
          );
          expect(result.exitCode, result.stderr).toBe(0);
          if (fixtureCase.extension === 'cjs') {
            const exactPrefix = bundled
              ? 'zntc: symbol-identity-prepass '
              : 'zntc: symbol-identity ';
            const exact = result.stderr.split(/\r?\n/).find((line) => line.startsWith(exactPrefix));
            expect(exact, result.stderr).toBeDefined();
            expect(exact).toMatch(/generated_bindings=[1-9]\d*/);
            expect(exact).toMatch(/generated_references=[1-9]\d*/);
            expect(exact).toMatch(/invalid_id=0(?:\s|$)/);
            expect(exact).toMatch(/duplicate_reference=0(?:\s|$)/);
            expect(exact).toMatch(/identity_mismatch=0(?:\s|$)/);
            expect(exact).toMatch(/binding_scope_mismatch=0(?:\s|$)/);
            expect(exact).toMatch(/unreachable_reference=0(?:\s|$)/);
            expect(exact).toMatch(/clean=1(?:\s|$)/);
          }
          if (fixtureCase.name.includes('control-flow result')) {
            const emitted = await Bun.file(out).text();
            expect(emitted).not.toContain('__zntc_loop_ret');
            if (
              fixtureCase.name ===
                'control-flow result names use the final standalone symbol set' &&
              !bundled &&
              !minify
            ) {
              expect(emitted).toContain('_ret3');
            }
          }
          const runtime = spawnSync('node', [out], { encoding: 'utf8' });
          expect(runtime.status).toBe(0);
          expect(runtime.stdout).toBe(native.stdout);
        });
      }
    }
  }
});
