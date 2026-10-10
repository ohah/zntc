import { afterEach, describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = [
  {
    name: 'each anonymous class self binding gets its final SymbolId name',
    source: `var First = class { static observedName = this.name; method() { return 1; } };
var Second = class { static observedName = this.name; method() { return 2; } };
console.log(new First().method(), new Second().method(), First.name, Second.name, First.observedName, Second.observedName);
`,
    expectsDistinctLateName: true,
  },
  {
    name: 'a simple anonymous class expression keeps its inferred name',
    source: `var Simple = class {};
console.log(Simple.name);
`,
  },
  {
    name: 'name restoration does not capture outer references after reassignment',
    source: `var Current = class { static read() { return Current; } };
var Original = Current;
Current = function Replacement() {};
console.log(Original.read() === Current, Original.name);
`,
  },
  {
    name: 'direct eval cannot see a generated anonymous class name',
    source: `var Holder = class { static read() { return eval('typeof _Class'); } };
console.log(Holder.read());
`,
  },
  {
    name: 'an unresolved global reference cannot be captured by the generated class name',
    source: `globalThis._Class = 41;
var Holder = class { static read() { return _Class; } };
console.log(Holder.read());
`,
  },
  {
    name: 'an unresolved numbered global cannot be captured by a late class name',
    source: `globalThis._Class2 = 41;
var First = class { read() { return _Class2; } };
var Second = class { read() { return _Class2; } };
console.log(new First().read(), new Second().read());
`,
    expectsReservedSuffixName: true,
  },
  {
    name: 'a source binding with the generated base name stays reserved',
    source: `const _Class = 42;
var Holder = class { static read() { return _Class; } };
console.log(Holder.read());
`,
  },
] as const;

const modes = [
  { name: 'standalone', args: [] },
  { name: 'bundle', args: ['--bundle', '--platform=node', '--format=esm'] },
  { name: 'identifier minify', args: ['--minify-identifiers', '--minify-syntax'] },
] as const;

describe('anonymous ES5 class expression symbol names (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixtureCase of cases) {
    for (const mode of modes) {
      test(`${fixtureCase.name}: ${mode.name}`, async () => {
        const fixture = await createFixture({
          'input.mjs': fixtureCase.source,
          'reference.mjs': fixtureCase.source,
          'package.json': '{"type":"module"}',
        });
        cleanup = fixture.cleanup;
        const native = spawnSync('node', [join(fixture.dir, 'reference.mjs')], {
          encoding: 'utf8',
        });
        expect(native.status, native.stderr).toBe(0);

        const output = join(fixture.dir, 'out.mjs');
        const result = await runZntcInDir(fixture.dir, [
          ...mode.args,
          'input.mjs',
          '--target=es5',
          '-o',
          output,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);

        const runtime = spawnSync('node', [output], { encoding: 'utf8' });
        expect(runtime.status, runtime.stderr).toBe(0);
        expect(runtime.stdout).toBe(native.stdout);

        if (fixtureCase.expectsDistinctLateName && mode.name === 'standalone') {
          const generated = readFileSync(output, 'utf8');
          expect(generated).toContain('_Class2');
        }
        if (fixtureCase.expectsReservedSuffixName && mode.name === 'standalone') {
          const generated = readFileSync(output, 'utf8');
          expect(generated).toContain('_Class3');
        }
      });
    }
  }
});
