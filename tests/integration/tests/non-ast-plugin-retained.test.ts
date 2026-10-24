import { describe, expect, test } from 'bun:test';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const zeroCounters = [
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
  'reference_statement_mismatch',
  'reference_scope_statement_alias',
  'reference_node_use_alias',
  'declaration_scope_mismatch',
  'declaration_identity_mismatch',
  'declaration_anchor_mismatch',
  'scope_map_mismatch',
  'scope_owner_mismatch',
  'scope_owner_parent_mismatch',
  'duplicate_scope_owner',
  'namespace_iife_param_mismatch',
  'enum_iife_param_mismatch',
  'helper_symbol_mismatch',
  'scope_resolution_mismatch',
  'invisible_reference',
  'reference_count_mismatch',
  'write_count_mismatch',
  'missing_binding',
  'missing_reference',
  'unclassified_reference',
];

const hooks = {
  resolve: `api.onResolve({filter:/dep/}, () => { calls.push('resolve'); return {path:dep}; });`,
  load: `api.onLoad({filter:/dep\\.ts$/}, () => { calls.push('load'); return {contents:'export const seed: number = 40;',loader:'ts'}; });`,
  transform: `api.onTransform({filter:/entry\\.ts$/}, args => { calls.push('transform'); return {code:args.code.replace('delta: number = 1','delta: number = 2')}; });`,
  render: `api.onRenderChunk({filter:/.*/}, args => { calls.push('render'); return {code:args.code+'\\n// output hook ran'}; });`,
  generate: `api.onGenerateBundle(() => { calls.push('generate'); });`,
  start: `api.onBuildStart(() => { calls.push('start'); });`,
  end: `api.onBuildEnd(() => { calls.push('end'); });`,
  close: `api.onCloseBundle(() => { calls.push('close'); });`,
  context: `api.onResolveContext({filter:/.*/}, () => { calls.push('context'); return {context:['./x.ts']}; });`,
};

function runCase(
  name: string,
  selected: (keyof typeof hooks)[],
  options: { ast?: boolean; worklet?: boolean; spoof?: boolean; downlevel?: boolean } = {},
) {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-non-ast-retained-'));
  const entry = join(dir, 'entry.ts');
  const dep = join(dir, 'dep.ts');
  const output = join(dir, 'out.cjs');
  const context = selected.includes('context');
  const source = options.downlevel
    ? 'var delta: number = 2; var read = (value: number) => value + delta; console.log(read(40));'
    : options.worklet
      ? 'export function read() { "worklet"; return 42; } console.log(read());'
      : `import { seed } from './dep'; var delta: number = ${selected.includes('transform') ? 1 : 2}; var read = (value: number) => value + delta; ${context ? "var ctx = require.context('./pages', false, /\\.ts$/); console.log(read(seed), ctx('./x.ts').seed);" : 'console.log(read(seed));'}`;
  writeFileSync(entry, source);
  writeFileSync(dep, 'export const seed: number = 40;');
  mkdirSync(join(dir, 'pages'));
  writeFileSync(join(dir, 'pages/x.ts'), 'export const seed: number = 40;');
  const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
  const runner = [
    `import {build,close} from ${JSON.stringify(coreEntry)};`,
    `const calls=[]; const dep=${JSON.stringify(dep)};`,
    `const result=await build({entryPoints:[${JSON.stringify(entry)}],platform:'node',format:'cjs',target:${JSON.stringify(options.downlevel ? 'es5' : 'esnext')},minifyIdentifiers:true,verbatimModuleSyntax:true,workletTransform:${!!options.worklet},write:false,plugins:[{name:${JSON.stringify(options.spoof ? 'reanimated-worklet' : name)},setup(api){${selected.map((hook) => hooks[hook]).join('\n')}${options.ast ? 'api.onAstFunction({filter:/.*/},()=>null);' : ''}}}]});`,
    `if(result.errors.length){console.error(JSON.stringify(result.errors));process.exit(1);}`,
    `process.stdout.write(JSON.stringify({calls,outputs:result.outputFiles.map(file=>file.text)}));close();`,
  ].join('\n');
  try {
    const run = Bun.spawnSync(['bun', '-e', runner], {
      cwd: join(import.meta.dir, '../../..'),
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
    });
    const stderr = run.stderr.toString();
    expect(run.exitCode, stderr).toBe(0);
    const result = JSON.parse(run.stdout.toString()) as { calls: string[]; outputs: string[] };
    for (const hook of selected) expect(result.calls, name).toContain(hook);
    expect(result.outputs).toHaveLength(1);
    writeFileSync(output, result.outputs[0]);
    const execution = Bun.spawnSync(['node', output]);
    expect(execution.exitCode, execution.stderr.toString()).toBe(0);
    expect(execution.stdout.toString()).toBe(context && !options.worklet ? '42 40\n' : '42\n');
    const identity = stderr
      .split(/\r?\n/)
      .filter((line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes(entry));
    expect(identity, stderr).toHaveLength(1);
    for (const field of [...zeroCounters, 'clean']) {
      const values = [...identity[0].matchAll(new RegExp(`(?:^| )${field}=(\\d+)(?= |$)`, 'g'))];
      expect(values, `${field}: ${identity[0]}`).toHaveLength(1);
      expect(Number(values[0][1]), field).toBe(field === 'clean' ? 1 : 0);
    }
    const mode = stderr
      .split(/\r?\n/)
      .filter(
        (line) => line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes(entry),
      );
    expect(mode, stderr).toHaveLength(1);
    expect(mode[0]).toContain(`semantic_graph=${options.ast ? 'reanalyzed' : 'retained'}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe('non-AST plugins preserve the transform semantic graph (#4819)', () => {
  for (const hook of Object.keys(hooks) as (keyof typeof hooks)[]) {
    test(`${hook} hook retains typed module graph`, () => runCase(hook, [hook]));
  }
  test('non-AST hooks retain an ES5 arrow lowering graph', () =>
    runCase('downlevel-observer', ['start', 'render'], { downlevel: true }));
  test('all nine non-AST hooks coexist', () =>
    runCase('all-hooks', Object.keys(hooks) as (keyof typeof hooks)[]));
  test('non-AST hooks coexist with the actual builtin worklet', () =>
    runCase('worklet-observer', ['transform', 'render', 'start', 'end', 'close'], {
      worklet: true,
    }));
  test('custom AST hooks retain the reanalysis boundary', () =>
    runCase('ast-plugin', [], { ast: true }));
  test('a user AST plugin cannot impersonate the builtin by name', () =>
    runCase('spoof', [], { ast: true, worklet: true, spoof: true }));
});
