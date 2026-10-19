import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

describe('Stage 3 decorator metadata names and direct eval', () => {
  test('metadata locals avoid ten eval-visible global decorator spellings', async () => {
    const evalExpressions = [
      "eval('_metadata')",
      "eval('\\u005fmetadata2')",
      "eval('_' + 'metadata3')",
      'eval(`_metadata4`)',
      "eval(('_metadata5'))",
      "eval('_metadata6 /* trailing comment */')",
      "eval(' _metadata7\\n')",
      "eval('\\x5fmetadata8')",
      "eval('\\u{5f}metadata9')",
      "eval('_meta' + 'data10')",
    ];
    const methods = evalExpressions
      .map((expression, index) => `  @${expression}\n  method${index}() { return ${index}; }`)
      .join('\n');
    const results = evalExpressions.map((_, index) => `value.method${index}()`).join(', ');
    const expected = `${evalExpressions.map((_, index) => index).join('|')}\n`;
    const fixture = await createFixture({
      'package.json': JSON.stringify({ type: 'module' }),
      'input.ts': `
const stem = '_' + 'meta' + 'data';
for (let suffix = 1; suffix <= 10; suffix++) {
  const globalName = suffix === 1 ? stem : stem + suffix;
  Object.defineProperty(globalThis, globalName, { value: (value: unknown) => value });
}
class Example {
${methods}
}
const value = new Example();
console.log([${results}].join('|'));
`,
    });

    try {
      const output = join(fixture.dir, 'output.mjs');
      const result = await runZntcInDir(fixture.dir, ['input.ts', '-o', output]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = await readFile(output, 'utf8');
      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe(expected);
      expect(code).toContain('const _metadata11 =');
    } finally {
      await fixture.cleanup();
    }
  });
});
