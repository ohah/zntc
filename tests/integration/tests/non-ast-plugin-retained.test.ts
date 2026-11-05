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

function runPluginLoadedImportEqualsDependency(
  useVirtualId: boolean,
  useSyncBuild = false,
  useAsyncHooks = false,
) {
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
  if (useSyncBuild && useAsyncHooks) {
    throw new Error('buildSync cannot run asynchronous plugin hooks');
  }
  const reportedEntry = realpathSync(entry);
  const reportedDependency = useVirtualId ? dependency : realpathSync(dependency);
  const resolveCallback = useAsyncHooks
    ? `async args=>{await Promise.resolve();calls.push('resolve:'+args.path);return {path:dependency};}`
    : `args=>{calls.push('resolve:'+args.path);return {path:dependency};}`;
  const resolveHook = useVirtualId
    ? `api.onResolve({filter:/^virtual:container$/},${resolveCallback});`
    : '';
  const loadCallback = useAsyncHooks
    ? `async args=>{await Promise.resolve();calls.push('load:'+args.path);return {contents:source,loader:'ts'};}`
    : `args=>{calls.push('load:'+args.path);return {contents:source,loader:'ts'};}`;
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
    `const result=${buildCall}({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[{name:'import-equals-plugin-dependency',setup(api){${resolveHook}api.onLoad({filter:${loadFilter}},${loadCallback});}}]});`,
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
    'async onResolve/onLoad virtual import-equals callbacks retain both module graphs',
    { timeout: 30_000 },
    () => runPluginLoadedImportEqualsDependency(true, false, true),
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

  test(
    'vitePlugin resolveId/load import-equals dependency retains both module graphs',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-rollup-import-equals-adapter-'));
      const entry = join(dir, 'entry.ts');
      const dependency = 'virtual:container.ts?rollup';
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
        "import Container = require('virtual:container');\nContainer.finish();\nconsole.log(Container.check());",
      );
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {build,close,vitePlugin} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const dependency=${JSON.stringify(dependency)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const plugin=vitePlugin({name:'rollup-import-equals-adapter',resolveId(id){if(id==='virtual:container'){calls.push('resolve:'+id);return dependency;}return null;},load(id){if(id===dependency){calls.push('load:'+id);return source;}return null;}});`,
        `const result=await build({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[plugin]});`,
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
        expect(result.calls).toEqual(['resolve:virtual:container', `load:${dependency}`]);
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
        for (const modulePath of [reportedEntry, dependency]) {
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

  test(
    'buildSync vitePlugin resolveId/load import-equals retains both module graphs',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-rollup-import-equals-'));
      const entry = join(dir, 'entry.ts');
      const dependency = 'virtual:container.ts?rollup';
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
        "import Container = require('virtual:container');\nContainer.finish();\nconsole.log(Container.check());",
      );
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync,vitePlugin} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const dependency=${JSON.stringify(dependency)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const plugin=vitePlugin({name:'buildsync-rollup-import-equals',resolveId(id){if(id==='virtual:container'){calls.push('resolve:'+id);return dependency;}return null;},load(id){if(id===dependency){calls.push('load:'+id);return source;}return null;}});`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[plugin]});`,
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
        expect(result.calls).toEqual(['resolve:virtual:container', `load:${dependency}`]);
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
        for (const modulePath of [reportedEntry, dependency]) {
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

  test(
    'async vitePlugin transform import-equals retains the transformed module graph',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-transform-import-equals-'));
      const entry = join(dir, 'entry.ts');
      const dependency = 'virtual:container.ts?rollup-transform';
      const source = [
        'namespace Container {',
        "  import Assert = require('node:assert/strict');",
        '  export function finish() { console.log("done"); return; }',
        '  export function check() {',
        '    const invoke = () => { Assert.equal(40 + 2, 42); return 41; };',
        '    return invoke();',
        '  }',
        '}',
        'export = Container;',
      ].join('\n');
      writeFileSync(
        entry,
        "import Container = require('virtual:container');\nContainer.finish();\nconsole.log(Container.check());",
      );
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {build,close,vitePlugin} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const dependency=${JSON.stringify(dependency)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const plugin=vitePlugin({name:'vite-transform-import-equals',resolveId(id){if(id==='virtual:container'){calls.push('resolve:'+id);return dependency;}return null;},load(id){if(id===dependency){calls.push('load:'+id);return source;}return null;},async transform(code,id){if(id===dependency){await Promise.resolve();calls.push('transform:'+id);return {code:code.replace('return 41;','return 42;')};}return null;}});`,
        `const result=await build({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[plugin]});`,
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
        expect(result.calls).toEqual([
          'resolve:virtual:container',
          `load:${dependency}`,
          `transform:${dependency}`,
        ]);
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
        for (const modulePath of [reportedEntry, dependency]) {
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

  test(
    'buildSync vitePlugin transform import-equals retains the transformed module graph',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-vite-transform-import-equals-'));
      const entry = join(dir, 'entry.ts');
      const dependency = 'virtual:container.ts?rollup-transform';
      const source = [
        'namespace Container {',
        "  import Assert = require('node:assert/strict');",
        '  export function finish() { console.log("done"); return; }',
        '  export function check() {',
        '    const invoke = () => { Assert.equal(40 + 2, 42); return 41; };',
        '    return invoke();',
        '  }',
        '}',
        'export = Container;',
      ].join('\n');
      writeFileSync(
        entry,
        "import Container = require('virtual:container');\nContainer.finish();\nconsole.log(Container.check());",
      );
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync,vitePlugin} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const dependency=${JSON.stringify(dependency)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const plugin=vitePlugin({name:'buildsync-vite-transform-import-equals',resolveId(id){if(id==='virtual:container'){calls.push('resolve:'+id);return dependency;}return null;},load(id){if(id===dependency){calls.push('load:'+id);return source;}return null;},transform(code,id){if(id===dependency){calls.push('transform:'+id);return {code:code.replace('return 41;','return 42;')};}return null;}});`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[plugin]});`,
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
        expect(result.calls).toEqual([
          'resolve:virtual:container',
          `load:${dependency}`,
          `transform:${dependency}`,
        ]);
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
        for (const modulePath of [reportedEntry, dependency]) {
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

  test(
    'buildSync onTransform TypeScript import-equals and export assignment retain exact captures',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-ontransform-import-equals-'));
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
        'export = Container;',
        'Container.finish();',
        'console.log(Container.check());',
      ].join('\n');
      writeFileSync(entry, '// buildSync onTransform supplies TypeScript source');
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[{name:'buildsync-ontransform-import-equals',setup(api){api.onTransform({filter:/entry\\.ts$/},args=>{calls.push(args.path);return {code:source};});}}]});`,
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
        expect(result.calls).toEqual([reportedEntry]);
        expect(result.outputs).toHaveLength(1);
        expect(result.outputs[0]).not.toContain('Container');
        expect(result.outputs[0]).not.toContain('=>');
        expect(result.outputs[0]).not.toMatch(/\breturn\s*;/);
        const output = join(dir, 'out.cjs');
        writeFileSync(output, result.outputs[0]);
        const execution = Bun.spawnSync([
          'node',
          '-e',
          `const api=require(${JSON.stringify(output)});if(typeof api.check!=='function'||api.check()!==42)process.exit(1);console.log('exports-ok');`,
        ]);
        expect(execution.exitCode, execution.stderr.toString()).toBe(0);
        expect(execution.stdout.toString()).toBe('done\n42\nexports-ok\n');

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
    'buildSync onTransform plain and namespace export-stars retain runtime exports',
    { timeout: 30_000 },
    () => {
      const cases = [
        { name: 'plain', statement: "export * from './dep.ts';", read: 'api.value' },
        { name: 'namespace', statement: "export * as ns from './dep.ts';", read: 'api.ns.value' },
      ];
      for (const fixture of cases) {
        const dir = mkdtempSync(
          join(tmpdir(), `zntc-buildsync-ontransform-export-star-${fixture.name}-`),
        );
        const entry = join(dir, 'entry.ts');
        const dependency = join(dir, 'dep.ts');
        const source = `${fixture.statement}\ninterface Marker { value: number }`;
        writeFileSync(entry, '// buildSync onTransform supplies TypeScript source');
        writeFileSync(dependency, 'export const value = 42; export const unused = 1;');
        const reportedEntry = realpathSync(entry);
        const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
        const runner = [
          `import {buildSync} from ${JSON.stringify(coreEntry)};`,
          `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const calls=[];`,
          `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'esnext',minifyIdentifiers:true,write:false,plugins:[{name:'buildsync-ontransform-export-star',setup(api){api.onTransform({filter:/entry\\.ts$/},args=>{calls.push(args.path);return {code:source};});}}]});`,
          `if(result.errors.length){console.error(JSON.stringify(result.errors));process.exit(1);}`,
          `process.stdout.write(JSON.stringify({calls,outputs:result.outputFiles.map(file=>file.text)}));`,
        ].join('\n');
        try {
          const run = Bun.spawnSync(['bun', '-e', runner], {
            cwd: join(import.meta.dir, '../../..'),
            env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          });
          const stderr = run.stderr.toString();
          expect(run.exitCode, `${fixture.name}: ${stderr}`).toBe(0);
          const result = JSON.parse(run.stdout.toString()) as {
            calls: string[];
            outputs: string[];
          };
          expect(result.calls, fixture.name).toEqual([reportedEntry]);
          expect(result.outputs, fixture.name).toHaveLength(1);
          const output = join(dir, 'out.cjs');
          writeFileSync(output, result.outputs[0]);
          const execution = Bun.spawnSync([
            'node',
            '-e',
            `const api=require(${JSON.stringify(output)});console.log(${fixture.read});`,
          ]);
          expect(execution.exitCode, `${fixture.name}: ${execution.stderr.toString()}`).toBe(0);
          expect(execution.stdout.toString(), fixture.name).toBe('42\n');

          const lines = stderr.split(/\r?\n/);
          const identity = lines.filter(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass ') && line.includes(reportedEntry),
          );
          expect(identity, `${fixture.name}: ${stderr}`).toHaveLength(1);
          for (const field of [...zeroCounters, 'clean']) {
            const values = [
              ...identity[0].matchAll(new RegExp(`(?:^| )${field}=(\\d+)(?= |$)`, 'g')),
            ];
            expect(values, `${fixture.name}: ${field}: ${identity[0]}`).toHaveLength(1);
            expect(Number(values[0][1]), `${fixture.name}: ${field}`).toBe(
              field === 'clean' ? 1 : 0,
            );
          }
          const mode = lines.filter(
            (line) =>
              line.startsWith('zntc: symbol-identity-prepass-mode ') &&
              line.includes(reportedEntry),
          );
          expect(mode, `${fixture.name}: ${stderr}`).toHaveLength(1);
          expect(mode[0], `${fixture.name}: ${mode[0]}`).toContain('semantic_graph=retained');
        } finally {
          rmSync(dir, { recursive: true, force: true });
        }
      }
    },
  );

  test(
    'buildSync onTransform erases declaration-level type imports and retains runtime imports',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-ontransform-import-type-'));
      const entry = join(dir, 'entry.ts');
      const dependency = join(dir, 'dependency.js');
      const types = join(dir, 'types.ts');
      const source = [
        "import { value as _value } from './dependency.js';",
        "import { tag as _tag } from './types.ts';",
        "import type { Shape as _Shape } from './types.ts';",
        'type Alias = _Shape;',
        'const result: Alias = { amount: _value + _tag - 1 };',
        'const read = () => result.amount + (1 + 2);',
        'console.log(read() - 3);',
      ].join('\n');
      writeFileSync(entry, '// buildSync onTransform supplies TypeScript source');
      writeFileSync(dependency, 'export const value = 42; export const unused = 1;');
      writeFileSync(types, 'export const tag = 1; export interface Shape { amount: number }');
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,verbatimModuleSyntax:true,write:false,plugins:[{name:'buildsync-ontransform-import-type',setup(api){api.onTransform({filter:/entry\\.ts$/},args=>{calls.push(args.path);return {code:source};});}}]});`,
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
        expect(result.calls).toEqual([reportedEntry]);
        expect(result.outputs).toHaveLength(1);
        expect(result.outputs[0]).not.toContain('_Shape');
        expect(result.outputs[0]).not.toContain('_value');
        expect(result.outputs[0]).not.toContain('Alias');
        expect(result.outputs[0]).not.toContain('Shape');
        expect(result.outputs[0]).not.toContain('result');
        expect(result.outputs[0]).not.toContain('read');
        expect(result.outputs[0]).not.toContain('=>');
        expect(result.outputs[0]).not.toMatch(/1\s*\+\s*2/);
        expect(result.outputs[0]).not.toContain('interface Shape');
        expect(result.outputs[0]).not.toContain('unused');
        const output = join(dir, 'out.cjs');
        writeFileSync(output, result.outputs[0]);
        const execution = Bun.spawnSync(['node', output]);
        expect(execution.exitCode, execution.stderr.toString()).toBe(0);
        expect(execution.stdout.toString()).toBe('42\n');

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
    'buildSync onTransform JSX helpers retain exact identities under same-name bindings',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-ontransform-jsx-'));
      const entry = join(dir, 'entry.tsx');
      const reactDir = join(dir, 'node_modules/react');
      mkdirSync(reactDir, { recursive: true });
      const source = [
        "const _jsx = () => 'user-jsx';",
        "const _jsxs = () => 'user-jsxs';",
        "const _Fragment = () => 'user-fragment';",
        'const value = 3;',
        'const element = <div data-x={value}><span>{_jsx()}</span><span>{_jsxs()}</span></div>;',
        'const fragment = <><span>fragment</span></>;',
        "console.log(_jsx(), _jsxs(), _Fragment(), element.type, element.props['data-x'], element.props.children.map(child => child.props.children).join(','), fragment.type);",
      ].join('\n');
      writeFileSync(entry, '// buildSync onTransform supplies TSX source');
      writeFileSync(
        join(reactDir, 'package.json'),
        JSON.stringify({ name: 'react', exports: { './jsx-runtime': './jsx-runtime.cjs' } }),
      );
      writeFileSync(
        join(reactDir, 'jsx-runtime.cjs'),
        "exports.jsx=(type,props)=>({type,props}); exports.jsxs=(type,props)=>({type,props}); exports.Fragment='fragment';",
      );
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',jsx:'automatic',external:['react/jsx-runtime'],minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[{name:'buildsync-ontransform-jsx',setup(api){api.onTransform({filter:/entry\\.tsx$/},args=>{calls.push(args.path);return {code:source};});}}]});`,
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
        expect(result.calls).toEqual([reportedEntry]);
        expect(result.outputs).toHaveLength(1);
        const helperNames = ['jsx', 'jsxs', 'Fragment'].map(
          (helper) =>
            result.outputs[0].match(
              new RegExp(`var ([A-Za-z_$][\\w$]*) = require\\("react/jsx-runtime"\\)\\.${helper};`),
            )?.[1],
        );
        expect(helperNames.every(Boolean)).toBe(true);
        expect(new Set(helperNames).size).toBe(3);
        expect(helperNames).not.toContain('_jsx');
        expect(helperNames).not.toContain('_jsxs');
        expect(helperNames).not.toContain('_Fragment');
        expect(result.outputs[0]).not.toContain('=>');
        const output = join(dir, 'out.cjs');
        writeFileSync(output, result.outputs[0]);
        const execution = Bun.spawnSync(['node', output]);
        expect(execution.exitCode, execution.stderr.toString()).toBe(0);
        expect(execution.stdout.toString()).toBe(
          'user-jsx user-jsxs user-fragment div 3 user-jsx,user-jsxs fragment\n',
        );

        const lines = stderr.split(/\r?\n/);
        const identity = lines.filter(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass ') && line.includes(reportedEntry),
        );
        expect(identity, stderr).toHaveLength(1);
        expect(identity[0]).toMatch(/generated_bindings=[1-9]\d* generated_references=[1-9]\d*/);
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
    'buildSync onTransform TypeScript enum IIFE keeps outer captures distinct',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-ontransform-enum-'));
      const entry = join(dir, 'entry.ts');
      const source = [
        'const _a = 40;',
        'enum Box { Value = _a + 2 }',
        'const read = () => _a;',
        'console.log(Box.Value, read());',
      ].join('\n');
      writeFileSync(entry, '// buildSync onTransform supplies TypeScript source');
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[{name:'buildsync-ontransform-enum',setup(api){api.onTransform({filter:/entry\\.ts$/},args=>{calls.push(args.path);return {code:source};});}}]});`,
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
        expect(result.calls).toEqual([reportedEntry]);
        expect(result.outputs).toHaveLength(1);
        expect(result.outputs[0]).not.toContain('enum');
        expect(result.outputs[0]).not.toContain('=>');
        const output = join(dir, 'out.cjs');
        writeFileSync(output, result.outputs[0]);
        const execution = Bun.spawnSync(['node', output]);
        expect(execution.exitCode, execution.stderr.toString()).toBe(0);
        expect(execution.stdout.toString()).toBe('42 40\n');

        const lines = stderr.split(/\r?\n/);
        const identity = lines.filter(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass ') && line.includes(reportedEntry),
        );
        expect(identity, stderr).toHaveLength(1);
        expect(identity[0]).toMatch(/enum_iife_params=1(?:\s|$)/);
        expect(identity[0]).toMatch(/enum_iife_param_mismatch=0(?:\s|$)/);
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
    'buildSync onTransform Flow match keeps generated callbacks and outer captures exact',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-ontransform-flow-match-'));
      const entry = join(dir, 'entry.js');
      const source = [
        "const _fallback = 'outer';",
        "const _m = 'user-m';",
        "const _m2 = 'user-m2';",
        'function classify(value) {',
        '  return match (value) {',
        '    { kind: 1, payload: const payload } if (payload > 0) => payload,',
        "    0 => 'zero',",
        '    _ => _fallback,',
        '  };',
        '}',
        'console.log(classify({ kind: 1, payload: 4 }), classify(0), classify(9), _m, _m2);',
      ].join('\n');
      writeFileSync(entry, '// buildSync onTransform supplies Flow source');
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',flow:true,minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[{name:'buildsync-ontransform-flow-match',setup(api){api.onTransform({filter:/entry\\.js$/},args=>{calls.push(args.path);return {code:source};});}}]});`,
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
        expect(result.calls).toEqual([reportedEntry]);
        expect(result.outputs).toHaveLength(1);
        expect(result.outputs[0]).not.toContain('match (');
        expect(result.outputs[0]).not.toContain('=>');
        const output = join(dir, 'out.cjs');
        writeFileSync(output, result.outputs[0]);
        const execution = Bun.spawnSync(['node', output]);
        expect(execution.exitCode, execution.stderr.toString()).toBe(0);
        expect(execution.stdout.toString()).toBe('4 zero outer user-m user-m2\n');

        const lines = stderr.split(/\r?\n/);
        const identity = lines.filter(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass ') && line.includes(reportedEntry),
        );
        expect(identity, stderr).toHaveLength(1);
        expect(identity[0]).toMatch(/generated_bindings=[1-9]\d* generated_references=[1-9]\d*/);
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
    'buildSync onTransform Flow enums retain runtime helpers and exact identities',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-ontransform-flow-enum-'));
      const entry = join(dir, 'entry.js');
      const runtime = join(dir, 'node_modules', 'flow-enums-runtime');
      const source = [
        '// @flow',
        "import flowEnums from 'flow-enums-runtime';",
        "const require = () => 'user-require';",
        "const Symbol = () => 'user-Symbol';",
        'enum LongColor { Red, Blue }',
        'enum LongShape of string { Circle, Square }',
        'function read() { return [LongColor.Red, LongShape.Circle]; }',
        'console.log(typeof flowEnums, typeof read()[0], read()[0].description, read()[1], require(), Symbol(), globalThis.flowEnumRuntimeLoads);',
      ].join('\n');
      writeFileSync(entry, '// buildSync onTransform supplies Flow source');
      mkdirSync(runtime, { recursive: true });
      writeFileSync(
        join(runtime, 'index.js'),
        [
          'globalThis.flowEnumRuntimeLoads = (globalThis.flowEnumRuntimeLoads || 0) + 1;',
          'function make(values) { return values; }',
          'make.Mirrored = (names) => make(Object.fromEntries(names.map((name) => [name, name])));',
          'module.exports = make;',
        ].join('\n'),
      );
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'esnext',flow:true,verbatimModuleSyntax:true,minifyIdentifiers:true,write:false,plugins:[{name:'buildsync-ontransform-flow-enum',setup(api){api.onTransform({filter:/entry\\.js$/},args=>{calls.push(args.path);return {code:source};});}}]});`,
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
        expect(result.calls).toEqual([reportedEntry]);
        expect(result.outputs).toHaveLength(1);
        const output = join(dir, 'out.cjs');
        writeFileSync(output, result.outputs[0]);
        const execution = Bun.spawnSync(['node', output]);
        expect(execution.exitCode, execution.stderr.toString()).toBe(0);
        expect(execution.stdout.toString()).toBe(
          'function symbol Red Circle user-require user-Symbol 1\n',
        );
        expect(result.outputs[0].match(/flowEnumRuntimeLoads\s*=\s*\(/g)).toHaveLength(1);

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
    'buildSync onTransform Stage 3 decorators retain generated helper identities',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-ontransform-stage3-decorator-'));
      const entry = join(dir, 'entry.ts');
      const source = [
        'const _classThis = 11, _method_decorators = 13, _metadata = 17;',
        'function identity(method, context) { return method; }',
        'function create(value) {',
        '  const outer = value + 4;',
        '  return class Generated {',
        '    @identity',
        '    method(argument) { return outer + argument; }',
        '  };',
        '}',
        'const Generated = create(6);',
        'console.log(new Generated().method(3), _classThis, _method_decorators, _metadata);',
      ].join('\n');
      writeFileSync(entry, '// buildSync onTransform supplies decorated TypeScript source');
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'esnext',minifyWhitespace:true,minifyIdentifiers:true,write:false,plugins:[{name:'buildsync-ontransform-stage3-decorator',setup(api){api.onTransform({filter:/entry\\.ts$/},args=>{calls.push(args.path);return {code:source};});}}]});`,
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
        expect(result.calls).toEqual([reportedEntry]);
        expect(result.outputs).toHaveLength(1);
        expect(result.outputs[0]).not.toContain('@identity');
        const output = join(dir, 'out.cjs');
        writeFileSync(output, result.outputs[0]);
        const execution = Bun.spawnSync(['node', output]);
        expect(execution.exitCode, execution.stderr.toString()).toBe(0);
        expect(execution.stdout.toString()).toBe('13 11 13 17\n');

        const lines = stderr.split(/\r?\n/);
        const identity = lines.filter(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass ') && line.includes(reportedEntry),
        );
        expect(identity, stderr).toHaveLength(1);
        expect(identity[0]).toMatch(/generated_bindings=[1-9]\d* generated_references=[1-9]\d*/);
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
    'buildSync onTransform legacy decorators retain generated helper identities',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-ontransform-legacy-decorator-'));
      const entry = join(dir, 'entry.ts');
      const source = [
        'const __decorate = 7, __metadata = 8;',
        'function identity(value, key, descriptor) {',
        '  if (descriptor && descriptor.value) {',
        '    const method = descriptor.value;',
        '    descriptor.value = function(argument) { return method.call(this, argument) + 38; };',
        '    return descriptor;',
        '  }',
        '  value.decorated = true;',
        '  return value;',
        '}',
        '@identity',
        'class Example {',
        '  @identity',
        '  method(value) { return value + 1; }',
        '}',
        'console.log(new Example().method(3), Example.decorated, __decorate, __metadata);',
      ].join('\n');
      writeFileSync(entry, '// buildSync onTransform supplies legacy-decorated TypeScript');
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'esnext',experimentalDecorators:true,minifyWhitespace:true,minifyIdentifiers:true,write:false,plugins:[{name:'buildsync-ontransform-legacy-decorator',setup(api){api.onTransform({filter:/entry\\.ts$/},args=>{calls.push(args.path);return {code:source};});}}]});`,
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
        expect(result.calls).toEqual([reportedEntry]);
        expect(result.outputs).toHaveLength(1);
        expect(result.outputs[0]).not.toContain('@identity');
        const output = join(dir, 'out.cjs');
        writeFileSync(output, result.outputs[0]);
        const execution = Bun.spawnSync(['node', output]);
        expect(execution.exitCode, execution.stderr.toString()).toBe(0);
        expect(execution.stdout.toString()).toBe('42 true 7 8\n');

        const lines = stderr.split(/\r?\n/);
        const identity = lines.filter(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass ') && line.includes(reportedEntry),
        );
        expect(identity, stderr).toHaveLength(1);
        expect(identity[0]).toMatch(/generated_bindings=[1-9]\d* generated_references=[1-9]\d*/);
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
    'buildSync onTransform ES5 for-of keeps per-iteration closure identities',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-ontransform-for-of-'));
      const entry = join(dir, 'entry.ts');
      const source = [
        "const _loop = 'user-loop';",
        "const _i = 'user-index';",
        'const values = [2, 3, 5];',
        'const readers = [];',
        'for (const value of values) { readers.push(() => value); }',
        "console.log(readers.map(read => read()).join(','), _loop, _i);",
      ].join('\n');
      writeFileSync(entry, '// buildSync onTransform supplies TypeScript for-of source');
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)}; const source=${JSON.stringify(source)}; const calls=[];`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[{name:'buildsync-ontransform-for-of',setup(api){api.onTransform({filter:/entry\\.ts$/},args=>{calls.push(args.path);return {code:source};});}}]});`,
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
        expect(result.calls).toEqual([reportedEntry]);
        expect(result.outputs).toHaveLength(1);
        expect(result.outputs[0]).not.toContain('=>');
        const output = join(dir, 'out.cjs');
        writeFileSync(output, result.outputs[0]);
        const execution = Bun.spawnSync(['node', output]);
        expect(execution.exitCode, execution.stderr.toString()).toBe(0);
        expect(execution.stdout.toString()).toBe('2,3,5 user-loop user-index\n');

        const lines = stderr.split(/\r?\n/);
        const identity = lines.filter(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass ') && line.includes(reportedEntry),
        );
        expect(identity, stderr).toHaveLength(1);
        expect(identity[0]).toMatch(/generated_bindings=[1-9]\d* generated_references=[1-9]\d*/);
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
});
