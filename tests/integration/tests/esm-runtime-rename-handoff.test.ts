import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

const COLLISION_CASES = Array.from({ length: 10 }, (_, index) =>
  Array.from({ length: index + 1 }, (_, suffix) => (suffix === 0 ? '__esm' : `__esm$${suffix + 1}`)),
);

describe('ESM runtime factory rename handoff by producer SymbolId (#5955)', () => {
  for (const [index, names] of COLLISION_CASES.entries()) {
    test(`post-link ESM reanalysis preserves collision-selected factory names — hostile input ${index + 1}`, async () => {
      const fixture = await createFixture({
        'dep.mjs':
          'export const BASE = 3;\n' +
          'export const SCALE = 4;\n' +
          'export const value = BASE * SCALE;\n' +
          'export function read() { return value; }\n',
        'entry.cjs':
          'const dep = require("./dep.mjs");\n' +
          `console.log(${names.map((name) => `typeof ${name}`).join(', ')}, ` +
          `eval(${JSON.stringify(names.map((name) => `typeof ${name}`).join(" + ' ' + "))}), ` +
          'dep.read());\n',
      });

      try {
        const output = join(fixture.dir, 'out.cjs');
        const result = await runZntc(
          [
            '--bundle',
            join(fixture.dir, 'entry.cjs'),
            '--platform=node',
            '--format=cjs',
            '--target=es5',
            '--minify-syntax',
            '-o',
            output,
          ],
          { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
        );
        expect(result.exitCode, `빌드 실패:\n${result.stderr}`).toBe(0);

        const depPath = join(fixture.dir, 'dep.mjs');
        const lines = result.stderr.split(/\r?\n/);
        const mode = lines.find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes(depPath),
        );
        expect(mode, `ESM module reanalysis가 확인되지 않음:\n${result.stderr}`).toContain(
          'semantic_graph=reanalyzed',
        );
        const audit = lines.find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes(depPath),
        );
        expect(audit, depPath).toContain('clean=1');

        const runtime = await runNode(output);
        const expected = [
          ...names.map(() => 'undefined'),
          names.map(() => 'undefined').join(' '),
          '12',
        ].join(' ');
        expect(runtime.stdout).toBe(expected);
        expect(runtime.stderr).toBe('');
      } finally {
        await fixture.cleanup();
      }
    });
  }
});
