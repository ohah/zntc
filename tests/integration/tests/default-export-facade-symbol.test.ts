import { afterEach, describe, expect, test } from 'bun:test';
import { realpathSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

const DEFAULT_CLASS_TARGETS = [
  { name: 'es5', flags: ['--target=es5'] },
  { name: 'es2015', flags: ['--target=es2015'] },
  { name: 'es2017', flags: ['--target=es2017'] },
  { name: 'es2022', flags: ['--target=es2022'] },
  { name: 'esnext', flags: ['--target=esnext'] },
  { name: 'hermes', flags: ['--platform=react-native'] },
] as const;

const DEFAULT_CLASS_MINIFY_MODES = [
  { name: 'plain', flags: [] },
  { name: 'identifiers', flags: ['--minify-identifiers'] },
  { name: 'identifiers-and-syntax', flags: ['--minify-identifiers', '--minify-syntax'] },
] as const;

const EXACT_PREPASS_ZERO_COUNTERS = [
  'invalid_id',
  'invalid_reference_node',
  'unreachable_reference',
  'ambiguous_ast_parent',
  'cyclic_ast_edges',
  'invalid_ast_root',
  'invalid_ast_edge',
  'invalid_ast_layout',
  'shadowed_external_reference',
  'duplicate_reference',
  'identity_mismatch',
  'binding_scope_mismatch',
  'binding_scope_unknown',
  'invalid_scope',
  'reference_scope_mismatch',
  'scope_map_mismatch',
  'scope_owner_mismatch',
  'scope_owner_parent_mismatch',
  'duplicate_scope_owner',
  'scope_strictness_mismatch',
  'namespace_iife_param_mismatch',
  'enum_iife_param_mismatch',
  'helper_symbol_mismatch',
  'scope_resolution_mismatch',
  'invisible_reference',
  'unclassified_reference',
  'reference_statement_mismatch',
  'reference_scope_statement_alias',
  'reference_node_use_alias',
  'declaration_scope_mismatch',
  'declaration_identity_mismatch',
  'declaration_anchor_mismatch',
  'reference_count_mismatch',
  'write_count_mismatch',
  'missing_binding',
  'missing_reference',
] as const;

function assertExactDefaultClassPrepass(
  stderr: string,
  sourceFile: string,
  requireGeneratedScopeOwners: boolean,
) {
  const lines = stderr.split(/\r?\n/);
  const sourcePath = realpathSync(sourceFile).replaceAll('\\', '/');
  const moduleReports = (prefix: string) =>
    lines.filter(
      (line) =>
        line.startsWith(prefix) && line.replaceAll('\\', '/').startsWith(`${prefix}${sourcePath}:`),
    );
  const modes = moduleReports('zntc: symbol-identity-prepass-mode ');
  const identities = moduleReports('zntc: symbol-identity-prepass ');
  const scopes = moduleReports('zntc: symbol-source-scope-owner ');

  expect(modes, stderr).toHaveLength(1);
  expect(modes[0], stderr).toContain('semantic_graph=retained');
  expect(identities, stderr).toHaveLength(1);
  expect(scopes, stderr).toHaveLength(1);

  const identity = identities[0] ?? '';
  expect(identity, stderr).toMatch(
    /invariant_counter_count=36 observation_field_count=8 diagnostic_field_count=17/,
  );
  expect(identity, stderr).toMatch(/clean=1(?:\s|$)/);
  expect(identity, stderr).toMatch(/schema_fingerprint=41454302a0dc783a(?:\s|$)/);
  for (const counter of EXACT_PREPASS_ZERO_COUNTERS) {
    expect(identity, `${counter}: ${identity}`).toMatch(new RegExp(`(?:^| )${counter}=0(?:\\s|$)`));
  }

  const observation = (field: string) => {
    const matches = identity.match(new RegExp(`(?:^| )${field}=(\\d+)(?=\\s|$)`, 'g')) ?? [];
    expect(matches, `${field}: ${identity}`).toHaveLength(1);
    return Number(matches[0]?.match(/=(\d+)/)?.[1] ?? -1);
  };
  expect(observation('declaration_anchors_checked')).toBeGreaterThan(0);
  if (requireGeneratedScopeOwners) {
    expect(observation('generated_bindings')).toBeGreaterThan(0);
    expect(observation('generated_references')).toBeGreaterThan(0);
    expect(observation('generated_scope_owners_checked')).toBeGreaterThanOrEqual(3);
  }

  for (const counter of [
    'scope_owner_mismatch',
    'scope_owner_parent_mismatch',
    'duplicate_scope_owner',
  ]) {
    expect(scopes[0], `${counter}: ${scopes[0]}`).toMatch(
      new RegExp(`(?:^| )${counter}=0(?:\\s|$)`),
    );
  }
}

describe('#4819 default export facade SymbolId', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const flags of [[], ['--minify-identifiers'], ['--minify-identifiers', '--minify-syntax']]) {
    test(`keeps a source _default separate from an anonymous default facade (${flags.length ? flags.join(' ') : 'plain'})`, async () => {
      const fixture = await createFixture({
        'entry.mjs': `
import value, { _default as local } from './dep.mjs';
console.log(JSON.stringify([value, local]));
`,
        'dep.mjs': `
const _default = 'source';
export { _default };
export default 42;
`,
      });
      cleanup = fixture.cleanup;

      const entry = join(fixture.dir, 'entry.mjs');
      const output = join(fixture.dir, 'bundle.mjs');
      const native = await runNode(entry);
      expect(native.stderr).toBe('');
      expect(native.stdout.trim()).toBe('[42,"source"]');

      const result = await runZntc(['--bundle', entry, '-o', output, '--format=esm', ...flags]);
      expect(result.exitCode, result.stderr).toBe(0);

      const bundled = await runNode(output);
      expect(bundled.stderr).toBe('');
      expect(bundled.stdout).toBe(native.stdout);
    });
  }

  const unresolvedGlobals = [
    { property: '_default', reference: '_default' },
    { property: 'snapshot', reference: 'snapshot' },
    { property: '$default', reference: '$default' },
    { property: '__default', reference: '__default' },
    { property: 'defaultValue', reference: 'defaultValue' },
    { property: 'reference', reference: 'reference' },
    { property: 'captured', reference: 'captured' },
    { property: 'moduleValue', reference: 'moduleValue' },
    { property: 'value_1', reference: 'value_1' },
    { property: '_default', reference: '\\u005fdefault' },
  ];

  for (const [index, scenario] of unresolvedGlobals.entries()) {
    test(`snapshots unresolved global default identifier (${index + 1}/10: ${scenario.reference})`, async () => {
      const fixture = await createFixture({
        'entry.mjs': `import value from './dep.mjs';\nconsole.log(JSON.stringify(value));\n`,
        'dep.mjs':
          `globalThis[${JSON.stringify(scenario.property)}] = 7;\n` +
          `export default ${scenario.reference};\n` +
          `globalThis[${JSON.stringify(scenario.property)}] = 9;\n`,
      });
      cleanup = fixture.cleanup;

      const entry = join(fixture.dir, 'entry.mjs');
      const native = await runNode(entry);
      expect(native.stderr).toBe('');
      expect(native.stdout.trim()).toBe('7');

      for (const format of ['esm', 'cjs'] as const) {
        const output = join(fixture.dir, `bundle.${format === 'esm' ? 'mjs' : 'cjs'}`);
        const result = await runZntc(['--bundle', entry, '-o', output, `--format=${format}`]);
        expect(result.exitCode, result.stderr).toBe(0);

        const bundled = await runNode(output);
        expect(bundled.stderr).toBe('');
        expect(bundled.stdout).toBe(native.stdout);
      }
    });
  }

  for (const flags of [[], ['--minify-identifiers'], ['--minify-identifiers', '--minify-syntax']]) {
    test(`keeps a named source _default when default exports that local (${flags.length ? flags.join(' ') : 'plain'})`, async () => {
      const fixture = await createFixture({
        'entry.mjs': `
import value, { _default as local } from './dep.mjs';
console.log(JSON.stringify([value, local]));
`,
        'dep.mjs': `
const _default = 'source';
export { _default };
export default _default;
`,
      });
      cleanup = fixture.cleanup;

      const entry = join(fixture.dir, 'entry.mjs');
      const output = join(fixture.dir, 'bundle.mjs');
      const native = await runNode(entry);
      expect(native.stderr).toBe('');
      expect(native.stdout.trim()).toBe('["source","source"]');

      const result = await runZntc(['--bundle', entry, '-o', output, '--format=esm', ...flags]);
      expect(result.exitCode, result.stderr).toBe(0);

      const bundled = await runNode(output);
      expect(bundled.stderr).toBe('');
      expect(bundled.stdout).toBe(native.stdout);
    });
  }

  for (const flags of [[], ['--minify-identifiers'], ['--minify-identifiers', '--minify-syntax']]) {
    test(`keeps a colliding source _default separate from a default re-export bridge (${flags.length ? flags.join(' ') : 'plain'})`, async () => {
      const fixture = await createFixture({
        'entry.mjs': `
import value, { _default as local } from './barrel.mjs';
console.log(JSON.stringify([value, local]));
`,
        'barrel.mjs': `
const _default = 'barrel local';
export { _default };
export { default } from './dep.mjs';
`,
        'dep.mjs': `export default 42;`,
      });
      cleanup = fixture.cleanup;

      const entry = join(fixture.dir, 'entry.mjs');
      const output = join(fixture.dir, 'bundle.mjs');
      const native = await runNode(entry);
      expect(native.stderr).toBe('');
      expect(native.stdout.trim()).toBe('[42,"barrel local"]');

      const result = await runZntc(['--bundle', entry, '-o', output, '--format=esm', ...flags]);
      expect(result.exitCode, result.stderr).toBe(0);

      const bundled = await runNode(output);
      expect(bundled.stderr).toBe('');
      expect(bundled.stdout).toBe(native.stdout);
    });
  }

  test('default class SymbolId and ScopeId reports stay exact across target/minify modes', async () => {
    const fixture = await createFixture({
      'anonymous-entry.mjs':
        "import DefaultClass, { _default as local } from './anonymous.mjs';\n" +
        'console.log(JSON.stringify([new DefaultClass().value(), local]));\n',
      'anonymous.mjs':
        "const _default = 'anonymous source';\n" +
        'export { _default };\n' +
        'export default class { value() { return _default; } }\n',
      'named-entry.mjs':
        "import DefaultClass, { _default as local } from './named.mjs';\n" +
        'console.log(JSON.stringify([new DefaultClass().value(), local]));\n',
      'named.mjs':
        "const _default = 'named source';\n" +
        'export { _default };\n' +
        'export default class Widget { value() { return _default; } }\n',
    });
    cleanup = fixture.cleanup;

    const cases = [
      {
        name: 'anonymous',
        entry: 'anonymous-entry.mjs',
        module: 'anonymous.mjs',
        expected: '["anonymous source","anonymous source"]',
      },
      {
        name: 'named',
        entry: 'named-entry.mjs',
        module: 'named.mjs',
        expected: '["named source","named source"]',
      },
    ] as const;
    let runs = 0;

    for (const testCase of cases) {
      const entry = join(fixture.dir, testCase.entry);
      const native = await runNode(entry);
      expect(native.stderr).toBe('');
      expect(native.stdout).toBe(testCase.expected);

      for (const target of DEFAULT_CLASS_TARGETS) {
        for (const mode of DEFAULT_CLASS_MINIFY_MODES) {
          const output = join(
            fixture.dir,
            `bundle-${testCase.name}-${target.name}-${mode.name}.mjs`,
          );
          const result = await runZntc(
            ['--bundle', entry, '-o', output, '--format=esm', ...target.flags, ...mode.flags],
            { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
          );
          expect(
            result.exitCode,
            `${testCase.name} ${target.name} ${mode.name}: ${result.stderr}`,
          ).toBe(0);

          const sourceModule = realpathSync(join(fixture.dir, testCase.module)).replaceAll(
            '\\',
            '/',
          );
          const identityPrefix = `zntc: symbol-identity-prepass ${sourceModule}:`;
          const hasIdentityReport = result.stderr
            .split(/\r?\n/)
            .some((line) => line.startsWith(identityPrefix));
          if (target.name === 'es5' || target.name === 'hermes') {
            expect(
              hasIdentityReport,
              `${testCase.name} ${target.name} ${mode.name}: ${result.stderr}`,
            ).toBe(true);
          }
          if (hasIdentityReport) {
            assertExactDefaultClassPrepass(
              result.stderr,
              sourceModule,
              target.name === 'es5' || target.name === 'hermes',
            );
          }

          const bundled = await runNode(output);
          expect(bundled.stderr, `${testCase.name} ${target.name} ${mode.name}`).toBe('');
          expect(bundled.stdout, `${testCase.name} ${target.name} ${mode.name}`).toBe(
            native.stdout,
          );
          runs++;
        }
      }
    }

    expect(runs).toBe(
      cases.length * DEFAULT_CLASS_TARGETS.length * DEFAULT_CLASS_MINIFY_MODES.length,
    );
  });

  test('anonymous default class keeps its facade identity on the retained ES5 graph', async () => {
    const fixture = await createFixture({
      'entry.mjs':
        "import DefaultClass, { _default as local } from './dep.mjs';\n" +
        'console.log(JSON.stringify([new DefaultClass().value(), local]));\n',
      'dep.mjs':
        "const _default = 'source';\n" +
        'export { _default };\n' +
        'export default class { value() { return _default; } }\n',
    });
    cleanup = fixture.cleanup;

    const entry = join(fixture.dir, 'entry.mjs');
    const output = join(fixture.dir, 'bundle.mjs');
    const native = await runNode(entry);
    expect(native.stderr).toBe('');
    expect(native.stdout.trim()).toBe('["source","source"]');

    const result = await runZntc(
      [
        '--bundle',
        entry,
        '-o',
        output,
        '--format=esm',
        '--target=es5',
        '--minify-identifiers',
        '--minify-syntax',
      ],
      {
        env: {
          ...process.env,
          ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
        },
      },
    );
    expect(result.exitCode, result.stderr).toBe(0);

    const lines = result.stderr.split(/\r?\n/);
    const mode = lines.find(
      (line) => line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('dep.mjs'),
    );
    const identity = lines.find(
      (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('dep.mjs'),
    );
    expect(mode, result.stderr).toContain('semantic_graph=retained');
    expect(identity, result.stderr).toMatch(/clean=1(?:\s|$)/);
    expect(identity).toMatch(/missing_binding=0(?:\s|$)/);
    expect(identity).toMatch(/declaration_identity_mismatch=0(?:\s|$)/);
    expect(identity).toMatch(/declaration_anchor_mismatch=0(?:\s|$)/);
    expect(identity).toMatch(/scope_owner_mismatch=0(?:\s|$)/);

    const bundled = await runNode(output);
    expect(bundled.stderr).toBe('');
    expect(bundled.stdout).toBe(native.stdout);
  });

  for (const flags of [[], ['--minify-whitespace'], ['--minify-syntax']]) {
    test(
      'keeps the default re-export bridge identity in preserve-modules (' +
        (flags.length ? flags.join(' ') : 'plain') +
        ')',
      async () => {
        const fixture = await createFixture({
          'entry.js':
            "import value, { _default as local } from './barrel.js';\nconsole.log(JSON.stringify([value, local]));\n",
          'barrel.js':
            "const _default = 'barrel local';\nexport { _default };\nexport { default } from './dep.js';\n",
          'dep.js': 'export default 42;',
        });
        cleanup = fixture.cleanup;

        const entry = join(fixture.dir, 'entry.js');
        const outDir = join(fixture.dir, 'out');
        writeFileSync(join(fixture.dir, 'package.json'), JSON.stringify({ type: 'module' }));
        const native = await runNode(entry);
        expect(native.stderr).toBe('');
        expect(native.stdout.trim()).toBe('[42,"barrel local"]');

        const result = await runZntc([
          '--bundle',
          entry,
          '--preserve-modules',
          '--preserve-modules-root=' + fixture.dir,
          '--outdir',
          outDir,
          '--format=esm',
          ...flags,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);

        writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
        const bundled = await runNode(join(outDir, 'entry.js'));
        expect(bundled.stderr).toBe('');
        expect(bundled.stdout).toBe(native.stdout);
      },
    );
  }

  test('keeps a default re-export bridge shared by entry and dynamic chunk', async () => {
    const fixture = await createFixture({
      'entry.js':
        "import value, { _default as local } from './barrel.js';\n" +
        'console.log(JSON.stringify([value, local]));\n' +
        "import('./lazy.js').then(({ read }) => console.log(read()));\n",
      'lazy.js':
        "import value, { _default as local } from './barrel.js';\n" +
        'export function read() { return JSON.stringify([value, local]); }\n',
      'barrel.js':
        "const _default = 'barrel local';\n" +
        'export { _default };\n' +
        "export { default } from './dep.js';\n",
      'dep.js': 'export default 42;',
    });
    cleanup = fixture.cleanup;

    const entry = join(fixture.dir, 'entry.js');
    const outDir = join(fixture.dir, 'out');
    writeFileSync(join(fixture.dir, 'package.json'), JSON.stringify({ type: 'module' }));
    const native = await runNode(entry);
    expect(native.stderr).toBe('');
    expect(native.stdout.trim().split('\n')).toEqual([
      '[42,"barrel local"]',
      '[42,"barrel local"]',
    ]);

    const result = await runZntc([
      '--bundle',
      entry,
      '--splitting',
      '--outdir',
      outDir,
      '--format=esm',
      '--platform=node',
    ]);
    expect(result.exitCode, result.stderr).toBe(0);

    writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
    const bundled = await runNode(join(outDir, 'entry.js'));
    expect(bundled.stderr).toBe('');
    expect(bundled.stdout).toBe(native.stdout);
  });

  test('named default class declaration retains its source binding through ES5 lowering', async () => {
    const fixture = await createFixture({
      'entry.mjs':
        "import DefaultClass, { _default as local } from './dep.mjs';\n" +
        'console.log(JSON.stringify([new DefaultClass().value(), local]));\n',
      'dep.mjs':
        "const _default = 'source';\n" +
        'export { _default };\n' +
        'export default class Widget { value() { return _default; } }\n',
    });
    cleanup = fixture.cleanup;

    const entry = join(fixture.dir, 'entry.mjs');
    const output = join(fixture.dir, 'bundle.mjs');
    const native = await runNode(entry);
    expect(native.stderr).toBe('');
    expect(native.stdout.trim()).toBe('["source","source"]');

    const result = await runZntc(
      [
        '--bundle',
        entry,
        '-o',
        output,
        '--format=esm',
        '--target=es5',
        '--minify-identifiers',
        '--minify-syntax',
      ],
      { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
    );
    expect(result.exitCode, result.stderr).toBe(0);

    const lines = result.stderr.split(/\r?\n/);
    const mode = lines.find(
      (line) => line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('dep.mjs'),
    );
    const identity = lines.find(
      (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('dep.mjs'),
    );
    expect(mode, result.stderr).toContain('semantic_graph=retained');
    expect(identity, result.stderr).toMatch(/clean=1(?:\s|$)/);
    expect(identity).toMatch(/missing_binding=0(?:\s|$)/);
    expect(identity).toMatch(/declaration_identity_mismatch=0(?:\s|$)/);
    expect(identity).toMatch(/declaration_anchor_mismatch=0(?:\s|$)/);
    expect(identity).toMatch(/scope_owner_mismatch=0(?:\s|$)/);

    const bundled = await runNode(output);
    expect(bundled.stderr).toBe('');
    expect(bundled.stdout).toBe(native.stdout);
  });
});
