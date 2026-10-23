import { describe, expect, test } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { createFixture, runNode, runZntc } from './helpers';

type NumericPostpassCase = {
  name: string;
  files: Record<string, string>;
  expected: string;
};

const CASES: NumericPostpassCase[] = [
  {
    name: 'dead branch delta with a direct imported read',
    files: {
      'values.ts': 'export const value = 41;',
      'entry.ts': `import { value } from './values';
if (false) console.log(value);
console.log(value);`,
    },
    expected: '41',
  },
  {
    name: 'aliased import with a dead optional branch',
    files: {
      'values.ts': 'export const answer = 42;',
      'entry.ts': `import { answer as imported } from './values';
if (false) { console.log(imported); }
console.log(imported);`,
    },
    expected: '42',
  },
  {
    name: 'two-hop re-export with a dead branch reference',
    files: {
      'values.ts': 'export const number = 43;',
      'bridge.ts': "export { number as value } from './values';",
      'entry.ts': `import { value } from './bridge';
if (false) console.log(value);
console.log(value);`,
    },
    expected: '43',
  },
  {
    name: 'multiple providers keep each symbol count independent',
    files: {
      'left.ts': 'export const left = 4;',
      'right.ts': 'export const right = 5;',
      'entry.ts': `import { left } from './left';
import { right } from './right';
if (false) console.log(left, right);
console.log(left, right);`,
    },
    expected: '4 5',
  },
  {
    name: 'negative numeric literal preserves unary semantics',
    files: {
      'values.ts': 'export const negative = -3;',
      'entry.ts': `import { negative } from './values';
if (false) console.log(negative);
console.log(negative);`,
    },
    expected: '-3',
  },
  {
    name: 'exponent numeric literal preserves its value',
    files: {
      'values.ts': 'export const exponent = 1e3;',
      'entry.ts': `import { exponent } from './values';
if (false) console.log(exponent);
console.log(exponent);`,
    },
    expected: '1000',
  },
  {
    name: 'same-spelled function parameter remains locally bound',
    files: {
      'values.ts': 'export const value = 7;',
      'entry.ts': `import { value } from './values';
if (false) console.log(value);
function addOne(value: number) { return value + 1; }
console.log(addOne(4), value);`,
    },
    expected: '5 7',
  },
  {
    name: 'live function-body reference survives alongside a materialized call argument',
    files: {
      'values.ts': 'export const value = 8;',
      'entry.ts': `import { value } from './values';
if (false) console.log(value);
function read() { return value; }
console.log(value, read());`,
    },
    expected: '8 8',
  },
  {
    name: 'object shorthand stays a reference while a direct read materializes',
    files: {
      'values.ts': 'export const value = 9;',
      'entry.ts': `import { value } from './values';
if (false) console.log(value);
console.log(value, JSON.stringify({ value }));`,
    },
    expected: '9 {"value":9}',
  },
  {
    name: 'class method read and direct read keep the provider identity',
    files: {
      'values.ts': 'export const value = 10;',
      'entry.ts': `import { value } from './values';
if (false) console.log(value);
class Reader { read() { return value; } }
console.log(value, new Reader().read());`,
    },
    expected: '10 10',
  },
];

async function buildPreserveModules(files: Record<string, string>) {
  const { dir, cleanup } = await createFixture(files);
  const outDir = join(dir, 'dist');
  const build = await runZntc([
    '--bundle',
    join(dir, 'entry.ts'),
    '--preserve-modules',
    '--outdir',
    outDir,
    '--format=esm',
    '--platform=node',
    '--minify-syntax',
  ]);
  if (build.exitCode !== 0) {
    await cleanup();
    throw new Error(`preserve-modules build failed:\n${build.stderr}`);
  }
  writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
  return { entry: join(outDir, 'entry.js'), cleanup };
}

describe('numeric post-pass keeps prepass ref deltas aligned on the retained graph', () => {
  for (const fixture of CASES) {
    test(fixture.name, async () => {
      const built = await buildPreserveModules(fixture.files);
      try {
        const { stdout } = await runNode(built.entry);
        expect(stdout.trim()).toBe(fixture.expected);
      } finally {
        await built.cleanup();
      }
    });
  }
});
