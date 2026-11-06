import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runNode, ZNTC_BIN } from './helpers';

const cases = {
  'instance accessor with initializer': {
    source: 'class Box { accessor value = 41; } console.log(new Box().value + 1);',
    expected: '42',
  },
  'instance accessor without initializer': {
    source:
      'class Box { accessor value; } const box = new Box(); box.value = 41; console.log(box.value + 1);',
    expected: '42',
  },
  'static accessor': {
    source: 'class Box { static accessor value = 41; } console.log(Box.value + 1);',
    expected: '42',
  },
  'static string computed key': {
    source: "class Box { accessor ['value'] = 41; } console.log(new Box().value + 1);",
    expected: '42',
  },
  'runtime computed key evaluated once': {
    source:
      "let calls = 0; const key = () => { calls++; return 'value'; }; class Box { accessor [key()] = 41; } console.log(calls, new Box().value + 1);",
    expected: '1 42',
  },
  'multiple instance accessors': {
    source:
      'class Box { accessor left = 20; accessor right = 22; } const box = new Box(); console.log(box.left + box.right);',
    expected: '42',
  },
  'class expression': {
    source: 'const Box = class { accessor value = 41; }; console.log(new Box().value + 1);',
    expected: '42',
  },
  'nested class expression': {
    source:
      'function create() { return class { accessor value = 41; }; } const Box = create(); console.log(new Box().value + 1);',
    expected: '42',
  },
  'derived class': {
    source:
      'class Base { constructor() { this.base = 40; } } class Box extends Base { accessor value = 2; } const box = new Box(); console.log(box.base + box.value);',
    expected: '42',
  },
  'default-export class': {
    source: 'export default class Box { accessor value = 41; } console.log(new Box().value + 1);',
    expected: '42',
  },
} as const;

describe('plain ES2022 auto-accessor graph pre-pass', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, { source, expected }] of Object.entries(cases)) {
    test(`${name} lowers while retaining exact generated identities`, async () => {
      const fixture = await createFixture({ 'entry.js': source });
      cleanup = fixture.cleanup;
      const input = join(fixture.dir, 'entry.js');
      const output = join(fixture.dir, 'out.cjs');

      const result = spawnSync(
        ZNTC_BIN,
        ['--bundle', input, '--target=es2022', '--platform=node', '--format=cjs', '-o', output],
        {
          cwd: fixture.dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );

      expect(result.status, result.stderr).toBe(0);
      expect(result.stderr).toContain('semantic_graph=retained');
      const report = result.stderr
        .replaceAll('\0', '\n')
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.js'),
        );
      expect(report, result.stderr).toBeDefined();
      expect(report).toMatch(/clean=1(?:\s|$)/);
      for (const counter of [
        'invalid_id',
        'missing_reference',
        'identity_mismatch',
        'scope_map_mismatch',
        'scope_owner_mismatch',
        'scope_owner_parent_mismatch',
        'declaration_identity_mismatch',
      ]) {
        expect(
          Number(report?.match(new RegExp(`(?:^| )${counter}=(\\d+)(?:\\s|$)`))?.[1] ?? -1),
          `${name} ${counter}: ${report}`,
        ).toBe(0);
      }

      const code = readFileSync(output, 'utf8');
      expect(code).not.toMatch(/\baccessor\s+value\b/);
      const execution = await runNode(output);
      expect(execution.stderr).toBe('');
      expect(execution.stdout).toBe(expected);
    });
  }
});
