import { describe, expect, test } from 'bun:test';
import { mkdtempSync, mkdirSync, realpathSync, writeFileSync, rmSync } from 'node:fs';
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
  const reportedEntry = realpathSync(entry);
  writeFileSync(dep, 'export const seed: number = 40;');
  mkdirSync(join(dir, 'pages'));
  writeFileSync(join(dir, 'pages/x.ts'), 'export const seed: number = 40;');
  const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
  const runner = [
    `import {build,close} from ${JSON.stringify(coreEntry)};`,
    `const calls=[]; const dep=${JSON.stringify(dep)};`,
    `const result=await build({entryPoints:[${JSON.stringify(entry)}],platform:'node',format:'cjs',target:${JSON.stringify(options.downlevel ? 'es5' : 'esnext')},minifyIdentifiers:true,verbatimModuleSyntax:true,workletTransform:${!!options.worklet},write:false,plugins:[{name:${JSON.stringify(options.spoof ? 'reanimated-worklet' : name)},setup(api){${selected.map((hook) => hooks[hook]).join('\n')}${options.ast ? "api.onAstFunction({filter:/.*/},()=>{calls.push('ast');return null;});" : ''}}}]});`,
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
    if (options.ast) expect(result.calls, name).toContain('ast');
    expect(result.outputs).toHaveLength(1);
    writeFileSync(output, result.outputs[0]);
    const execution = Bun.spawnSync(['node', output]);
    expect(execution.exitCode, execution.stderr.toString()).toBe(0);
    expect(execution.stdout.toString()).toBe(context && !options.worklet ? '42 40\n' : '42\n');
    const identity = stderr
      .split(/\r?\n/)
      .filter(
        (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes(reportedEntry),
      );
    expect(identity, stderr).toHaveLength(1);
    for (const field of [...zeroCounters, 'clean']) {
      const values = [...identity[0].matchAll(new RegExp(`(?:^| )${field}=(\\d+)(?= |$)`, 'g'))];
      expect(values, `${field}: ${identity[0]}`).toHaveLength(1);
      expect(Number(values[0][1]), field).toBe(field === 'clean' ? 1 : 0);
    }
    const mode = stderr
      .split(/\r?\n/)
      .filter(
        (line) =>
          line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes(reportedEntry),
      );
    expect(mode, stderr).toHaveLength(1);
    expect(mode[0]).toContain('semantic_graph=retained');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function runPluginLoadedImportEqualsDependency(useVirtualId: boolean, useSyncBuild = false) {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-import-equals-plugin-dependency-'));
  const entry = join(dir, 'entry.ts');
  const dependency = useVirtualId ? 'virtual:container.ts?plugin' : join(dir, 'dep.ts');
  const specifier = useVirtualId ? 'virtual:container' : './dep.ts';
  const source = [
    'namespace Container {',
    "  import Assert = require('node:assert/strict');",
    '  export function finish() { console.log("done"); return; }',
    '  export function check() {',
    '    const invoke = () => { Assert.equal(40 + 2, 42); return 42; };',
    '    return invoke();',
    '  }',
    '}',
    'export = Container;',
  ].join('\n');
  writeFileSync(
    entry,
    `import Container = require('${specifier}');\nContainer.finish();\nconsole.log(Container.check());`,
  );
  if (!useVirtualId) {
    writeFileSync(dependency, '// onLoad supplies the dependency TypeScript source');
  }
  const reportedEntry = realpathSync(entry);
  const reportedDependency = useVirtualId ? dependency : realpathSync(dependency);
  const resolveHook = useVirtualId
    ? `api.onResolve({filter:/^virtual:container$/},args=>{calls.push('resolve:'+args.path);return {path:dependency};});`
    : '';
  const loadFilter = useVirtualId ? '/virtual:container\\.ts\\?plugin$/' : '/dep\\.ts$/';
  const expectedCalls = useVirtualId
    ? ['resolve:virtual:container', `load:${reportedDependency}`]
    : [`load:${reportedDependency}`];
  const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
  const buildImport = useSyncBuild
    ? `import {buildSync} from ${JSON.stringify(coreEntry)};`
    : `import {build,close} from ${JSON.stringify(coreEntry)};`;
  const buildCall = useSyncBuild ? 'buildSync' : 'await build';
  const closeCall = useSyncBuild ? '' : 'close();';
  const runner = [
    buildImport,
    `const entry=${JSON.stringify(entry)}; const dependency=${JSON.stringify(dependency)}; const source=${JSON.stringify(source)}; const calls=[];`,
    `const result=${buildCall}({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[{name:'import-equals-plugin-dependency',setup(api){${resolveHook}api.onLoad({filter:${loadFilter}},args=>{calls.push('load:'+args.path);return {contents:source,loader:'ts'};});}}]});`,
    `if(result.errors.length){console.error(JSON.stringify(result.errors));process.exit(1);}`,
    `process.stdout.write(JSON.stringify({calls,outputs:result.outputFiles.map(file=>file.text)}));${closeCall}`,
  ].join('\n');
  try {
    const run = Bun.spawnSync(['bun', '-e', runner], {
      cwd: join(import.meta.dir, '../../..'),
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
    });
    const stderr = run.stderr.toString();
    expect(run.exitCode, stderr).toBe(0);
    const result = JSON.parse(run.stdout.toString()) as {
      calls: string[];
      outputs: string[];
    };
    expect(result.calls).toEqual(expectedCalls);
    expect(result.outputs).toHaveLength(1);
    expect(result.outputs[0]).not.toContain('Container');
    expect(result.outputs[0]).not.toContain('=>');
    expect(result.outputs[0]).not.toMatch(/\breturn\s*;/);
    const output = join(dir, 'out.cjs');
    writeFileSync(output, result.outputs[0]);
    const execution = Bun.spawnSync(['node', output]);
    expect(execution.exitCode, execution.stderr.toString()).toBe(0);
    expect(execution.stdout.toString()).toBe('done\n42\n');

    const lines = stderr.split(/\r?\n/);
    for (const modulePath of [reportedEntry, reportedDependency]) {
      const identity = lines.filter(
        (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes(modulePath),
      );
      expect(identity, `${modulePath}: ${stderr}`).toHaveLength(1);
      for (const field of [...zeroCounters, 'clean']) {
        const values = [...identity[0].matchAll(new RegExp(`(?:^| )${field}=(\\d+)(?= |$)`, 'g'))];
        expect(values, `${modulePath}: ${field}: ${identity[0]}`).toHaveLength(1);
        expect(Number(values[0][1]), `${modulePath}: ${field}`).toBe(field === 'clean' ? 1 : 0);
      }
      const mode = lines.filter(
        (line) =>
          line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes(modulePath),
      );
      expect(mode, `${modulePath}: ${stderr}`).toHaveLength(1);
      expect(mode[0], `${modulePath}: ${mode[0]}`).toContain('semantic_graph=retained');
    }
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
  test('a no-op custom AST hook preserves exact output identity', () =>
    runCase('ast-plugin', [], { ast: true }));
  test('a user AST plugin cannot impersonate the builtin by name', () =>
    runCase('spoof', [], { ast: true, worklet: true, spoof: true }));

  test(
    'onLoad TypeScript import-equals preserves exact captures across ES targets and minify flags',
    { timeout: 120_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-import-equals-onload-'));
      const entry = join(dir, 'entry.ts');
      const source = [
        'namespace Container {',
        "  import Assert = require('node:assert/strict');",
        '  export function finish() { console.log("done"); return; }',
        '  export function check() {',
        '    const invoke = () => { Assert.equal(40 + 2, 42); return 42; };',
        '    return invoke();',
        '  }',
        '}',
        'Container.finish();',
        'console.log(Container.check());',
      ].join('\n');
      const targets = [
        'es5',
        'es2015',
        'es2016',
        'es2017',
        'es2018',
        'es2019',
        'es2020',
        'es2021',
        'es2022',
        'es2023',
        'es2024',
        'es2025',
        'esnext',
      ];
      const minifyModes = [
        { name: 'plain', whitespace: false, syntax: false, identifiers: false },
        { name: 'whitespace', whitespace: true, syntax: false, identifiers: false },
        { name: 'syntax', whitespace: false, syntax: true, identifiers: false },
        { name: 'syntax-whitespace', whitespace: true, syntax: true, identifiers: false },
        { name: 'identifiers', whitespace: false, syntax: false, identifiers: true },
        { name: 'identifiers-whitespace', whitespace: true, syntax: false, identifiers: true },
        { name: 'syntax-identifiers', whitespace: false, syntax: true, identifiers: true },
        { name: 'full', whitespace: true, syntax: true, identifiers: true },
      ];
      const expectedCaseCount = 104;
      expect(targets).toHaveLength(13);
      expect(minifyModes).toHaveLength(8);
      writeFileSync(entry, '// onLoad supplies the TypeScript source');
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {build,close} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const targets=${JSON.stringify(targets)}; const minifyModes=${JSON.stringify(minifyModes)}; const cases=[];`,
        `for(const target of targets) for(const mode of minifyModes){const calls=[];const result=await build({entryPoints:[entry],platform:'node',format:'cjs',target,minifyWhitespace:mode.whitespace,minifySyntax:mode.syntax,minifyIdentifiers:mode.identifiers,write:false,plugins:[{name:'import-equals-onload',setup(api){api.onLoad({filter:/entry\\.ts$/},args=>{calls.push(args.path);return {contents:source,loader:'ts'};});}}]});if(result.errors.length){console.error(JSON.stringify({target,mode:mode.name,errors:result.errors}));process.exit(1);}cases.push({target,mode:mode.name,calls,outputs:result.outputFiles.map(file=>file.text)});}`,
        `process.stdout.write(JSON.stringify(cases));close();`,
      ].join('\n');
      try {
        const run = Bun.spawnSync(['bun', '-e', runner], {
          cwd: join(import.meta.dir, '../../..'),
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        });
        const stderr = run.stderr.toString();
        expect(run.exitCode, stderr).toBe(0);
        const cases = JSON.parse(run.stdout.toString()) as {
          target: string;
          mode: string;
          calls: string[];
          outputs: string[];
        }[];
        expect(cases).toHaveLength(expectedCaseCount);
        const casesByKey = new Map(cases.map((item) => [`${item.target}/${item.mode}`, item]));
        expect(casesByKey.size).toBe(expectedCaseCount);
        for (const target of targets) {
          for (const mode of minifyModes) {
            const fixture = casesByKey.get(`${target}/${mode.name}`);
            expect(fixture, `${target}/${mode.name}`).toBeDefined();
            expect(fixture?.calls, `${target}/${mode.name}`).toEqual([reportedEntry]);
            expect(fixture?.outputs, `${target}/${mode.name}`).toHaveLength(1);
            const generated = fixture!.outputs[0];
            if (mode.syntax) {
              expect(generated, `${target}/${mode.name}`).not.toMatch(/\breturn\s*;/);
            } else {
              expect(generated, `${target}/${mode.name}`).toMatch(/\breturn\s*;/);
            }
            if (mode.identifiers) {
              expect(generated, `${target}/${mode.name}`).not.toContain('Container');
            } else {
              expect(generated, `${target}/${mode.name}`).toContain('Container');
            }
            if (target === 'es5') {
              expect(generated, `${target}/${mode.name}`).not.toContain('=>');
            } else {
              expect(generated, `${target}/${mode.name}`).toContain('=>');
            }
            const output = join(dir, `out-${target}-${mode.name}.cjs`);
            writeFileSync(output, generated);
            const execution = Bun.spawnSync(['node', output]);
            expect(execution.exitCode, `${target}/${mode.name}: ${execution.stderr}`).toBe(0);
            expect(execution.stdout.toString(), `${target}/${mode.name}`).toBe('done\n42\n');
          }
        }

        for (const target of targets) {
          for (const mode of minifyModes.filter((candidate) => !candidate.whitespace)) {
            const uncompressed = casesByKey.get(`${target}/${mode.name}`)?.outputs[0];
            const compressed = casesByKey.get(
              `${target}/${minifyModes.find((candidate) => candidate.whitespace === true && candidate.syntax === mode.syntax && candidate.identifiers === mode.identifiers)?.name}`,
            )?.outputs[0];
            expect(uncompressed, `${target}/${mode.name}`).toBeDefined();
            expect(compressed, `${target}/${mode.name} whitespace`).toBeDefined();
            expect(uncompressed!.length, `${target}/${mode.name} whitespace`).toBeGreaterThan(
              compressed!.length,
            );
          }
        }

        const lines = stderr.split(/\r?\n/);
        const identity = lines.filter(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass ') && line.includes(reportedEntry),
        );
        expect(identity, stderr).toHaveLength(expectedCaseCount);
        for (const [index, report] of identity.entries()) {
          for (const field of [...zeroCounters, 'clean']) {
            const values = [...report.matchAll(new RegExp(`(?:^| )${field}=(\\d+)(?= |$)`, 'g'))];
            expect(values, `${index}: ${field}: ${report}`).toHaveLength(1);
            expect(Number(values[0][1]), `${index}: ${field}`).toBe(field === 'clean' ? 1 : 0);
          }
        }
        const mode = lines.filter(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes(reportedEntry),
        );
        expect(mode, stderr).toHaveLength(expectedCaseCount);
        for (const [index, report] of mode.entries()) {
          expect(report, `${index}: ${report}`).toContain('semantic_graph=retained');
        }
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    },
  );

  test(
    'onLoad dependency import-equals retains both module graphs through ES5 minification',
    { timeout: 30_000 },
    () => runPluginLoadedImportEqualsDependency(false),
  );
  test(
    'onResolve and onLoad virtual import-equals dependency retain both module graphs',
    { timeout: 30_000 },
    () => runPluginLoadedImportEqualsDependency(true),
  );
  test(
    'buildSync onResolve/onLoad virtual import-equals dependency retains both graphs',
    { timeout: 30_000 },
    () => runPluginLoadedImportEqualsDependency(true, true),
  );

  test(
    'onTransform-provided TypeScript import-equals retains exact captures through ES5 minification',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-import-equals-ontransform-'));
      const entry = join(dir, 'entry.ts');
      const source = [
        'namespace Container {',
        "  import Assert = require('node:assert/strict');",
        '  export function finish() { console.log("done"); return; }',
        '  export function check() {',
        '    const invoke = () => { Assert.equal(40 + 2, 42); return 42; };',
        '    return invoke();',
        '  }',
        '}',
        'Container.finish();',
        'console.log(Container.check());',
      ].join('\n');
      writeFileSync(entry, '// onTransform supplies the TypeScript source');
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {build,close} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const result=await build({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[{name:'import-equals-ontransform',setup(api){api.onTransform({filter:/entry\\.ts$/},args=>{calls.push(args.path);return {code:source};});}}]});`,
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
        const result = JSON.parse(run.stdout.toString()) as {
          calls: string[];
          outputs: string[];
        };
        expect(result.calls).toEqual([reportedEntry]);
        expect(result.outputs).toHaveLength(1);
        expect(result.outputs[0]).not.toContain('Container');
        expect(result.outputs[0]).not.toContain('=>');
        expect(result.outputs[0]).not.toMatch(/\breturn\s*;/);
        const output = join(dir, 'out.cjs');
        writeFileSync(output, result.outputs[0]);
        const execution = Bun.spawnSync(['node', output]);
        expect(execution.exitCode, execution.stderr.toString()).toBe(0);
        expect(execution.stdout.toString()).toBe('done\n42\n');

        const lines = stderr.split(/\r?\n/);
        const identity = lines.filter(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass ') && line.includes(reportedEntry),
        );
        expect(identity, stderr).toHaveLength(1);
        for (const field of [...zeroCounters, 'clean']) {
          const values = [
            ...identity[0].matchAll(new RegExp(`(?:^| )${field}=(\\d+)(?= |$)`, 'g')),
          ];
          expect(values, `${field}: ${identity[0]}`).toHaveLength(1);
          expect(Number(values[0][1]), field).toBe(field === 'clean' ? 1 : 0);
        }
        const mode = lines.filter(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes(reportedEntry),
        );
        expect(mode, stderr).toHaveLength(1);
        expect(mode[0]).toContain('semantic_graph=retained');
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    },
  );

  test(
    'buildSync plugin-loaded import-equals retains both module graphs through ES5 minification',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-import-equals-plugin-'));
      const entry = join(dir, 'entry.ts');
      const dependency = join(dir, 'dep.ts');
      const source = [
        'namespace Container {',
        "  import Assert = require('node:assert/strict');",
        '  export function finish() { console.log("done"); return; }',
        '  export function check() {',
        '    const invoke = () => { Assert.equal(40 + 2, 42); return 42; };',
        '    return invoke();',
        '  }',
        '}',
        'export = Container;',
      ].join('\n');
      writeFileSync(
        entry,
        "import Container = require('./dep.ts');\nContainer.finish();\nconsole.log(Container.check());",
      );
      writeFileSync(dependency, '// buildSync onLoad supplies the dependency TypeScript source');
      const reportedEntry = realpathSync(entry);
      const reportedDependency = realpathSync(dependency);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[{name:'buildsync-import-equals-plugin',setup(api){api.onLoad({filter:/dep\\.ts$/},args=>{calls.push(args.path);return {contents:source,loader:'ts'};});}}]});`,
        `if(result.errors.length){console.error(JSON.stringify(result.errors));process.exit(1);}`,
        `process.stdout.write(JSON.stringify({calls,outputs:result.outputFiles.map(file=>file.text)}));`,
      ].join('\n');
      try {
        const run = Bun.spawnSync(['bun', '-e', runner], {
          cwd: join(import.meta.dir, '../../..'),
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        });
        const stderr = run.stderr.toString();
        expect(run.exitCode, stderr).toBe(0);
        const result = JSON.parse(run.stdout.toString()) as {
          calls: string[];
          outputs: string[];
        };
        expect(result.calls).toEqual([reportedDependency]);
        expect(result.outputs).toHaveLength(1);
        expect(result.outputs[0]).not.toContain('Container');
        expect(result.outputs[0]).not.toContain('=>');
        expect(result.outputs[0]).not.toMatch(/\breturn\s*;/);
        const output = join(dir, 'out.cjs');
        writeFileSync(output, result.outputs[0]);
        const execution = Bun.spawnSync(['node', output]);
        expect(execution.exitCode, execution.stderr.toString()).toBe(0);
        expect(execution.stdout.toString()).toBe('done\n42\n');

        const lines = stderr.split(/\r?\n/);
        for (const modulePath of [reportedEntry, reportedDependency]) {
          const identity = lines.filter(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes(modulePath),
          );
          expect(identity, `${modulePath}: ${stderr}`).toHaveLength(1);
          for (const field of [...zeroCounters, 'clean']) {
            const values = [
              ...identity[0].matchAll(new RegExp(`(?:^| )${field}=(\\d+)(?= |$)`, 'g')),
            ];
            expect(values, `${modulePath}: ${field}: ${identity[0]}`).toHaveLength(1);
            expect(Number(values[0][1]), `${modulePath}: ${field}`).toBe(field === 'clean' ? 1 : 0);
          }
          const mode = lines.filter(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes(modulePath),
          );
          expect(mode, `${modulePath}: ${stderr}`).toHaveLength(1);
          expect(mode[0], `${modulePath}: ${mode[0]}`).toContain('semantic_graph=retained');
        }
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    },
  );
});
