import { afterEach, describe, expect, test } from 'bun:test';
import { writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runNode, ZNTC_JS_CLI } from './helpers';

describe('React Refresh graph pre-pass path gate', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('non-target CommonJS modules skip the graph pre-pass', async () => {
    const fixture = await createFixture({
      'input.cjs':
        'function App() { return null; } const answer = 42; process.stdout.write(String(answer));',
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'output.cjs');
    const result = spawnSync(
      'bun',
      [
        ZNTC_JS_CLI,
        '--bundle',
        join(fixture.dir, 'input.cjs'),
        '-o',
        output,
        '--platform=node',
        '--format=cjs',
        '--react-refresh=true',
      ],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(result.status, result.stderr).toBe(0);
    expect(result.stderr).not.toContain('zntc: symbol-identity-prepass-mode ');

    const execution = await runNode(output);
    expect(execution.stderr).toBe('');
    expect(execution.stdout).toBe('42');
  });

  test('React Refresh and Worklet preserve their exact identities together', async () => {
    const fixture = await createFixture({
      'entry.jsx':
        'const _c = 41; export function App(value) { "worklet"; return _c + value; } export const helper = (value) => { "worklet"; return _c + value; };',
    });
    cleanup = fixture.cleanup;
    const entry = join(fixture.dir, 'entry.jsx');
    const output = join(fixture.dir, 'output.cjs');
    const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
    const build = (source: string) => {
      writeFileSync(entry, source);
      const runner = [
        `import { build } from ${JSON.stringify(coreEntry)};`,
        `const result = await build(${JSON.stringify({
          entryPoints: [entry],
          platform: 'node',
          format: 'cjs',
          target: 'esnext',
          workletTransform: true,
          reactRefresh: true,
          minifyIdentifiers: true,
          write: false,
        })});`,
        'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
        'process.stdout.write(JSON.stringify(result.outputFiles.map((file) => file.text)));',
      ].join('\n');
      return spawnSync('bun', ['-e', runner], {
        cwd: join(import.meta.dir, '../../..'),
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      });
    };

    const assertReport = (stderr: string, expectedMode: 'retained' | 'reanalyzed') => {
      const report = stderr
        .split(/\r?\n/)
        .find(
          (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('entry.jsx'),
        );
      expect(report, stderr).toBeDefined();
      expect(report).toMatch(/schema_fingerprint=[0-9a-f]+(?:\s|$)/);
      for (const counter of [
        'missing_binding',
        'missing_reference',
        'identity_mismatch',
        'binding_scope_mismatch',
        'reference_scope_mismatch',
        'scope_owner_mismatch',
        'unclassified_reference',
        'declaration_identity_mismatch',
      ]) {
        expect(report, counter).toMatch(new RegExp(`(?:^|\\s)${counter}=0(?:\\s|$)`));
      }
      expect(report).toMatch(/clean=1(?:\s|$)/);
      if (expectedMode === 'retained')
        expect(Number(report!.match(/generated_bindings=(\d+)/)?.[1] ?? 0)).toBeGreaterThanOrEqual(
          2,
        );
      const mode = stderr
        .split(/\r?\n/)
        .find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('entry.jsx'),
        );
      expect(mode, stderr).toContain(`semantic_graph=${expectedMode}`);
    };

    const result = build(
      'const _c = 41; export function App(value) { "worklet"; return _c + value; } export const helper = (value) => { "worklet"; return _c + value; };',
    );
    expect(result.status, result.error?.message ?? result.stderr).toBe(0);
    assertReport(result.stderr, 'retained');
    const outputs = JSON.parse(result.stdout) as string[];
    expect(outputs).toHaveLength(1);
    expect(outputs[0]).toContain('__workletHash');
    expect(outputs[0]).toContain('__closure');
    writeFileSync(output, outputs[0]);

    const actual = spawnSync(
      'node',
      [
        '-e',
        [
          'globalThis.__refresh = [];',
          'globalThis.$RefreshReg$ = (component, name) => __refresh.push([name, component.name]);',
          `const { App, helper } = require(${JSON.stringify(output)});`,
          'console.log(App(2), helper(2), JSON.stringify(__refresh));',
        ].join('\n'),
      ],
      { encoding: 'utf8' },
    );
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe('43 43 [["App","App"]]\n');

    const evalResult = build(
      'export function App(value) { "worklet"; return eval("value + 40"); }',
    );
    expect(evalResult.status, evalResult.error?.message ?? evalResult.stderr).toBe(0);
    assertReport(evalResult.stderr, 'reanalyzed');
    const evalOutputs = JSON.parse(evalResult.stdout) as string[];
    expect(evalOutputs).toHaveLength(1);
    writeFileSync(output, evalOutputs[0]);
    const evalActual = spawnSync(
      'node',
      [
        '-e',
        [
          'globalThis.__refresh = [];',
          'globalThis.$RefreshReg$ = (component, name) => __refresh.push([name, component.name]);',
          `const { App } = require(${JSON.stringify(output)});`,
          'console.log(App(2), JSON.stringify(__refresh));',
        ].join('\n'),
      ],
      { encoding: 'utf8' },
    );
    expect(evalActual.status, evalActual.stderr).toBe(0);
    expect(evalActual.stdout).toBe('42 [["App","App"]]\n');

    const nestedResult = build(
      'export function App(value) { "worklet"; function inner(input) { "worklet"; return input + 40; } return inner(value); }',
    );
    expect(nestedResult.status, nestedResult.error?.message ?? nestedResult.stderr).toBe(0);
    assertReport(nestedResult.stderr, 'reanalyzed');
    const nestedOutputs = JSON.parse(nestedResult.stdout) as string[];
    expect(nestedOutputs).toHaveLength(1);
    writeFileSync(output, nestedOutputs[0]);
    const nestedActual = spawnSync(
      'node',
      [
        '-e',
        [
          'globalThis.__refresh = [];',
          'globalThis.$RefreshReg$ = (component, name) => __refresh.push([name, component.name]);',
          `const { App } = require(${JSON.stringify(output)});`,
          'console.log(App(2), JSON.stringify(__refresh));',
        ].join('\n'),
      ],
      { encoding: 'utf8' },
    );
    expect(nestedActual.status, nestedActual.stderr).toBe(0);
    expect(nestedActual.stdout).toBe('42 [["App","App"]]\n');
  });
});
