import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, runZntcInDir } from './helpers';

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
          const fixture = await createFixture({
            [inputName]: fixtureCase.source,
            'reference.mjs': reference,
          });
          cleanup = fixture.cleanup;
          const native = spawnSync('node', [join(fixture.dir, 'reference.mjs')], {
            encoding: 'utf8',
          });
          expect(native.status).toBe(0);
          expect(native.stdout.trim().length).toBeGreaterThan(0);
          const out = join(fixture.dir, 'out.cjs');
          const result = await runZntcInDir(fixture.dir, [
            ...(bundled ? ['--bundle'] : []),
            inputName,
            '--target=es5',
            ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
            ...(bundled ? ['--platform=node', '--format=cjs'] : []),
            '-o',
            out,
          ]);
          expect(result.exitCode).toBe(0);
          const runtime = spawnSync('node', [out], { encoding: 'utf8' });
          expect(runtime.status).toBe(0);
          expect(runtime.stdout).toBe(native.stdout);
        });
      }
    }
  }
});
