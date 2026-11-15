import { parseSync } from '@swc/core';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

type Output = { path: string; contents: Uint8Array; moduleIds?: string[]; exports?: string[] };
type Node = Record<string, any>;
function walk(node: any, visit: (node: Node) => void): void {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) {
    for (const child of node) walk(child, visit);
    return;
  }
  if (typeof node.type === 'string') visit(node);
  for (const [key, value] of Object.entries(node)) if (key !== 'span') walk(value, visit);
}

// Resolve the compiler provider by output provenance, not a generated filename
// or local spelling. Parse actual import/forwarder bindings before observing it.
export function helperGuardSites(outputs: readonly Output[], outputDirectory: string): string[][] {
  const providers = outputs.filter((output) =>
    output.moduleIds?.includes('\0zntc:runtime/keep-names'),
  );
  if (!providers.length) return [];
  if (providers.length !== 1) throw new Error('ambiguous keep-names provider');
  const provider = providers[0];
  const providerPath = resolve(outputDirectory, provider.path);
  const providerAst = parseSync(Buffer.from(provider.contents).toString('utf8'), {
    syntax: 'ecmascript',
    target: 'esnext',
  });
  const initializerLocals = new Set<string>();
  const initializerExports = new Set<string>();
  walk(providerAst, (node) => {
    if (
      node.type === 'VariableDeclarator' &&
      node.id.type === 'Identifier' &&
      node.init?.type === 'CallExpression' &&
      node.init.arguments.length === 1 &&
      node.init.arguments[0].expression.type === 'ObjectExpression' &&
      node.init.arguments[0].expression.properties.some(
        (property: Node) => property.type === 'MethodProperty',
      )
    )
      initializerLocals.add(node.id.value);
  });
  walk(providerAst, (node) => {
    if (node.type === 'ExportNamedDeclaration')
      for (const specifier of node.specifiers) {
        if (specifier.type === 'ExportSpecifier' && initializerLocals.has(specifier.orig.value))
          initializerExports.add(specifier.exported?.value ?? specifier.orig.value);
      }
    if (
      node.type === 'AssignmentExpression' &&
      node.operator === '=' &&
      node.right.type === 'Identifier' &&
      initializerLocals.has(node.right.value) &&
      node.left.type === 'MemberExpression' &&
      node.left.object.type === 'Identifier' &&
      node.left.object.value === 'exports' &&
      node.left.property.type === 'Identifier'
    )
      initializerExports.add(node.left.property.value);
  });
  if (!initializerExports.size) throw new Error('missing actual helper initializer export');
  const guardProviders = outputs.filter((output) =>
    output.moduleIds?.includes('\0zntc:runtime/split-entry-guard'),
  );
  if (guardProviders.length !== 1) throw new Error('missing exact guard provider');
  const guardPath = resolve(outputDirectory, guardProviders[0].path);
  const guardExports = new Set(guardProviders[0].exports);
  const sites: string[][] = [];
  for (const output of outputs) {
    if (!output.moduleIds?.some((id) => !id.startsWith('\0'))) continue;
    const outputPath = resolve(outputDirectory, output.path);
    const source = Buffer.from(output.contents).toString('utf8');
    const ast = parseSync(source, { syntax: 'ecmascript', target: 'esnext' });
    const bindings = new Set<string>();
    const resolvesProvider = (text: string) => resolve(dirname(outputPath), text) === providerPath;
    walk(ast, (node) => {
      if (node.type === 'ImportDeclaration' && resolvesProvider(node.source.value)) {
        for (const specifier of node.specifiers) {
          if (
            specifier.type === 'ImportSpecifier' &&
            initializerExports.has(specifier.imported?.value ?? specifier.local.value)
          )
            bindings.add(specifier.local.value);
        }
      }
      // CJS forwarding functions preserve the provider's exported initializer.
      if (
        node.type !== 'VariableDeclarator' ||
        node.id.type !== 'Identifier' ||
        node.init?.type !== 'FunctionExpression'
      )
        return;
      let actualRequire = false;
      let exportedCall = false;
      walk(node.init, (child) => {
        if (
          child.type === 'CallExpression' &&
          child.callee.type === 'Identifier' &&
          child.callee.value === 'require' &&
          child.arguments[0]?.expression.type === 'StringLiteral' &&
          resolvesProvider(child.arguments[0].expression.value)
        )
          actualRequire = true;
        if (
          child.type === 'MemberExpression' &&
          child.property.type === 'Identifier' &&
          initializerExports.has(child.property.value)
        )
          exportedCall = true;
      });
      if (actualRequire && exportedCall) bindings.add(node.id.value);
    });
    const guards = new Set<string>();
    const accessors = new Set<string>();
    const namespaces = new Set<string>();
    const guardRequire = (node: Node) =>
      node?.type === 'CallExpression' &&
      node.callee.type === 'Identifier' &&
      node.callee.value === 'require' &&
      node.arguments[0]?.expression.type === 'StringLiteral' &&
      resolve(dirname(outputPath), node.arguments[0].expression.value) === guardPath;
    const memberKey = (node: Node) =>
      node.type === 'Identifier'
        ? node.value
        : node.type === 'Computed' && node.expression.type === 'StringLiteral'
          ? node.expression.value
          : undefined;
    walk(ast, (node) => {
      if (
        node.type === 'ImportDeclaration' &&
        resolve(dirname(outputPath), node.source.value) === guardPath
      )
        for (const specifier of node.specifiers) {
          if (
            specifier.type === 'ImportSpecifier' &&
            guardExports.has(specifier.imported?.value ?? specifier.local.value)
          )
            guards.add(specifier.local.value);
        }
      if (node.type === 'FunctionDeclaration')
        walk(node.body, (child) => {
          if (child.type === 'ReturnStatement' && guardRequire(child.argument))
            accessors.add(node.identifier.value);
        });
    });
    walk(ast, (node) => {
      if (
        node.type === 'VariableDeclarator' &&
        node.id.type === 'Identifier' &&
        node.init?.type === 'CallExpression' &&
        node.init.callee.type === 'Identifier' &&
        accessors.has(node.init.callee.value)
      )
        namespaces.add(node.id.value);
    });
    walk(ast, (node) => {
      if (
        node.type === 'VariableDeclarator' &&
        node.id.type === 'Identifier' &&
        node.init?.type === 'MemberExpression' &&
        guardExports.has(memberKey(node.init.property)) &&
        (guardRequire(node.init.object) ||
          (node.init.object.type === 'Identifier' && namespaces.has(node.init.object.value)))
      )
        guards.add(node.id.value);
    });
    const guardedBindings = new Map<string, number>();
    walk(ast, (node) => {
      if (
        node.type !== 'CallExpression' ||
        node.callee.type !== 'Identifier' ||
        !guards.has(node.callee.value) ||
        node.arguments.length !== 1 ||
        node.arguments[0].expression.type !== 'Identifier' ||
        !bindings.has(node.arguments[0].expression.value)
      )
        return;
      const binding = node.arguments[0].expression.value;
      guardedBindings.set(binding, (guardedBindings.get(binding) ?? 0) + 1);
      // SWC spans are UTF-8 byte offsets; V8 stack columns are UTF-16 units.
      const prefix = Buffer.from(source)
        .subarray(0, node.span.start - ast.span.start)
        .toString('utf8');
      const lines = prefix.split('\n');
      const location = `:${lines.length}:${lines.at(-1)!.length + 1}`;
      sites.push([`${outputPath}${location}`, `${pathToFileURL(outputPath).href}${location}`]);
    });
    for (const binding of bindings)
      if (guardedBindings.get(binding) !== 1)
        throw new Error('helper initializer binding must have one actual guard call');
  }
  return sites;
}

export const observeGuardReads =
  "const guardStacks=[];Object.defineProperty(globalThis,'ErrorUtils',{configurable:true,get(){guardStacks.push(new Error().stack);return undefined}});";

// Keep the original Source-call expectation separate from constructor calls.
// Each helper callsite must execute exactly once; unrelated reads remain Source
// reads and therefore cannot disappear behind a blanket count adjustment.
export function printSourceGuardReads(sites: string[][]): string {
  return `const helperSites=${JSON.stringify(sites)};const hits=helperSites.map(()=>0);let sourceReads=0;for(const stack of guardStacks){const frames=stack.split('\\n').slice(3);const matched=helperSites.map((locations,i)=>locations.some(location=>frames.some(frame=>frame.endsWith(location+')')||frame.endsWith(location)))?i:-1).filter(i=>i>=0);if(matched.length>1)throw Error('ambiguous helper guard read');if(matched.length)hits[matched[0]]++;else sourceReads++}if(hits.some(n=>n!==1))throw Error('helper initializer guard was not observed exactly once: '+JSON.stringify(hits));console.log(sourceReads);`;
}

// Oracle controls use tiny parsed outputs, not a second compiler invocation.
// A missing guard must fail even though the Source count alone could still pass.
import { expect, test } from 'bun:test';
function observerFixture(body: string): Output[] {
  const output = (
    path: string,
    moduleId: string,
    code: string,
    exports: string[] = [],
  ): Output => ({
    path,
    moduleIds: [moduleId],
    contents: Buffer.from(code),
    exports,
  });
  return [
    output('helper.js', '\0zntc:runtime/keep-names', 'var init=wrap({body(){}});export{init};'),
    output(
      'guard.js',
      '\0zntc:runtime/split-entry-guard',
      'export function guard(fn){return fn()}',
      ['guard'],
    ),
    output(
      'entry.js',
      '/source/entry.mjs',
      `import{init}from'./helper.js';import{guard}from'./guard.js';${body}`,
    ),
  ];
}

test('eager imports use actual source Scope0 callers oracle rejects absent or unrelated helper guards', () => {
  for (const body of ['init();', 'unrelated(init);', 'guard(init);guard(init);']) {
    expect(() => helperGuardSites(observerFixture(body), '/output')).toThrow(
      'helper initializer binding must have one actual guard call',
    );
  }
});

test('eager imports use actual source Scope0 callers oracle rejects repeated helper reads and missing Source reads', () => {
  const sites = helperGuardSites(observerFixture('guard(init);'), '/output');
  expect(sites).toHaveLength(1);
  const helperStack = `Error\n at getter\n at guard\n at caller (${sites[0][0]})`;
  const sourceStack = 'Error\n at getter\n at guard\n at caller (/output/source.js:1:1)';
  const observe = (stacks: string[], expectedSourceReads: number) => {
    let actual: number | undefined;
    new Function('guardStacks', 'console', printSourceGuardReads(sites))(stacks, {
      log(value: number) {
        actual = value;
      },
    });
    if (actual !== expectedSourceReads) throw new Error('Source caller count changed');
  };
  expect(() => observe([helperStack, sourceStack], 1)).not.toThrow();
  expect(() => observe([helperStack, helperStack, sourceStack], 1)).toThrow(
    'helper initializer guard was not observed exactly once',
  );
  expect(() => observe([helperStack], 1)).toThrow('Source caller count changed');
});
