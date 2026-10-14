import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5820: after #5807 the bundle path still dropped every other early error the
// analyzer reports. Duplicate exports bundled into code that silently lost one
// of the values, `export { nope }` became a ReferenceError, and the rest bundled
// into code that throws a SyntaxError on load. Node, esbuild, rolldown and
// webpack all reject these. Legal TS patterns that look similar must keep
// bundling.
describe('bundle reports semantic early errors (#5820)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const invalid: Record<string, [string, string]> = {
    'duplicate default export': ['export default 1;\nexport default 2;\n', 'Duplicate export'],
    'duplicate export name': [
      'const a = 1, b = 2;\nexport { a, b as a };\n',
      "Duplicate export name 'a'",
    ],
    'export of an undeclared name': ['export { nope };\n', "Export 'nope' is not defined"],
    'undeclared private name': [
      'class A { #a; m() { return this.#b; } }\nconsole.log(A);\n',
      "Private field '#b'",
    ],
    'duplicate private name': [
      'class A { #a; #a; }\nconsole.log(A);\n',
      "'#a' has already been declared",
    ],
    'duplicate constructor': [
      'class A { constructor() {} constructor() {} }\nconsole.log(A);\n',
      'one constructor',
    ],
    'undefined break label': ['for (;;) { break nope; }\n', "Undefined label 'nope'"],
    'duplicate label': ['l: l: ;\n', "Label 'l' has already been declared"],
    'continue to a non-loop label': [
      'l: { for (;;) { continue l; } }\n',
      "Cannot continue to non-loop label 'l'",
    ],
    'getter with a parameter': [
      'const o = { get x(a) { return 1; } };\nconsole.log(o);\n',
      'Getter must not have any formal parameters',
    ],
    'duplicate __proto__': [
      'const o = { __proto__: null, __proto__: null };\nconsole.log(o);\n',
      '__proto__ appears more than once',
    ],
  };
  for (const [name, [source, message]] of Object.entries(invalid)) {
    test(`rejects ${name}`, async () => {
      const created = await createFixture({ 'entry.mjs': source });
      cleanup = created.cleanup;
      const entry = join(created.dir, 'entry.mjs');
      const syntax = spawnSync('node', ['--check', entry], { encoding: 'utf8' });
      expect(syntax.status).not.toBe(0);
      const result = await runZntc(['--bundle', entry, '-o', join(created.dir, 'out.mjs')]);
      expect(result.exitCode, result.stderr).not.toBe(0);
      expect(result.stderr).toContain(message);
    });
  }

  test('still bundles legal TS overloads, accessors and type exports', async () => {
    const created = await createFixture({
      'types.ts':
        'export interface Shape { w: number }\nexport type Id = string;\nexport const Id = "id";\n',
      'entry.ts': `import type { Shape } from "./types";
import { Id } from "./types";
interface Local { a: number }
type Alias = number;
class P {
  constructor(a: string);
  constructor(a: number);
  constructor(public a: any) {}
  get v(this: P): number { return 1; }
  set v(this: P, x: number) {}
}
function over(a: string): string;
function over(a: number): number;
function over(a: any) { return a; }
enum E { A }
enum E { B = 2 }
const o = { __proto__: null as any, ["__proto__"]: 1 };
export { Local, Alias, Shape, Id };
export type { Alias as A2 };
export default class D {}
console.log(new P(1).v, over(2), E.A, E.B, Id, Object.keys(o).length);
`,
    });
    cleanup = created.cleanup;
    const out = join(created.dir, 'out.js');
    const result = await runZntc(['--bundle', join(created.dir, 'entry.ts'), '-o', out]);
    expect(result.exitCode, result.stderr).toBe(0);
    const run = spawnSync('node', [out], { encoding: 'utf8' });
    expect(run.status, run.stderr).toBe(0);
    expect(run.stdout).toBe('1 2 0 2 id 1\n');
  });
});
