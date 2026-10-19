import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

describe('JSX runtime names and direct eval', () => {
  test('automatic JSX keeps ten eval-visible global spellings reachable', async () => {
    const evalExpressions = [
      "eval('_jsx')",
      "eval('_jsx2')",
      "eval('\\u005fjsx3')",
      "eval('_' + 'jsx4')",
      'eval(`_jsx5`)',
      "eval(('_jsx6'))",
      "eval('_jsx7 /* trailing comment */')",
      "eval(' _jsx8\\n')",
      "eval('\\x5fjsx9')",
      "eval('_jsx' + '10')",
    ];
    const globals = evalExpressions
      .map((_, index) => `globalThis._jsx${index === 0 ? '' : index + 1} = 'global${index}';`)
      .join('\n');
    const readers = evalExpressions
      .map((expression, index) => `function read${index}() { return ${expression}; }`)
      .join('\n');
    const readValues = evalExpressions.map((_, index) => `read${index}()`).join(', ');
    const sharedSource = `${globals}\n${readers}\n`;
    const expected = `${evalExpressions.map((_, index) => `global${index}`).join('|')}|div\n`;

    const fixture = await createFixture({
      'package.json': JSON.stringify({ type: 'module' }),
      'node_modules/react/package.json': JSON.stringify({
        type: 'module',
        exports: { './jsx-runtime': './jsx-runtime.mjs' },
      }),
      'node_modules/react/jsx-runtime.mjs': `
export function jsx(type, props) { return { type, props }; }
export const Fragment = Symbol.for('fragment');
`,
      'input.jsx': `${sharedSource}const element = <div />;\nconsole.log([${readValues}, element.type].join('|'));\n`,
      'reference.mjs': `${sharedSource}const element = { type: 'div' };\nconsole.log([${readValues}, element.type].join('|'));\n`,
    });

    try {
      const output = join(fixture.dir, 'output.mjs');
      const result = await runZntcInDir(fixture.dir, [
        'input.jsx',
        '-o',
        output,
        '--jsx=automatic',
        '--minify-identifiers',
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = await readFile(output, 'utf8');
      const transformed = spawnSync('node', [output], { encoding: 'utf8' });
      expect(transformed.status, transformed.stderr).toBe(0);
      const reference = spawnSync('node', [join(fixture.dir, 'reference.mjs')], {
        encoding: 'utf8',
      });
      expect(reference.status, reference.stderr).toBe(0);
      expect(reference.stdout).toBe(expected);
      expect(transformed.stdout).toBe(reference.stdout);
      expect(code).toContain('jsx as _jsx11');
      expect(code).toMatch(/_jsx11\("div"/);
    } finally {
      await fixture.cleanup();
    }
  });
});
