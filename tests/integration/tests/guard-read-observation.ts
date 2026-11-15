import { parseSync } from '@swc/core';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

type Output = { path: string; contents: Uint8Array; moduleIds?: string[]; exports?: string[] };
type Node = Record<string, any>;
function bindingKey(node: Node): string {
  return `${node.ctxt}:${node.value}`;
}
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
            bindings.add(bindingKey(specifier.local));
        }
      }
      // CJS forwarding functions preserve the provider's exported initializer.
      if (
        node.type !== 'VariableDeclarator' ||
        node.id.type !== 'Identifier' ||
        node.init?.type !== 'FunctionExpression'
      )
        return;
      const fn = node.init;
      const actualRequire = (value: Node) =>
        value?.type === 'CallExpression' &&
        value.callee.type === 'Identifier' &&
        value.callee.value === 'require' &&
        value.arguments.length === 1 &&
        value.arguments[0].expression.type === 'StringLiteral' &&
        resolvesProvider(value.arguments[0].expression.value);
      const sameIdentifier = (left: Node, right: Node) =>
        left?.type === 'Identifier' &&
        right?.type === 'Identifier' &&
        left.value === right.value &&
        left.ctxt === right.ctxt;
      let mentionsRequire = false;
      let mentionsInitializer = false;
      walk(fn, (child) => {
        if (actualRequire(child)) mentionsRequire = true;
        if (
          child.type === 'MemberExpression' &&
          child.property.type === 'Identifier' &&
          initializerExports.has(child.property.value)
        )
          mentionsInitializer = true;
      });
      if (!mentionsRequire || !mentionsInitializer) return;
      // Authenticate the generated forwarder's actual dataflow, not two
      // unrelated descendants. Its first local owns require(provider), its
      // exported initializer is called through that exact binding, and the
      // call's result is what the forwarder returns.
      const first = fn.body?.stmts[0];
      const required =
        first?.type === 'VariableDeclaration' && first.declarations.length === 1
          ? first.declarations[0]
          : undefined;
      const owner = required?.id;
      let valid =
        fn.params.length === 0 && owner?.type === 'Identifier' && actualRequire(required.init);
      let ownerDeclarations = 0;
      let ownerWritten = false;
      walk(fn, (child) => {
        if (child.type === 'VariableDeclarator' && sameIdentifier(child.id, owner))
          ownerDeclarations++;
        if (
          (child.type === 'AssignmentExpression' && sameIdentifier(child.left, owner)) ||
          (child.type === 'UpdateExpression' && sameIdentifier(child.argument, owner))
        )
          ownerWritten = true;
        if (
          child.type === 'VariableDeclarator' &&
          child.id.type === 'Identifier' &&
          (child.id.value === 'arguments' || child.id.value === 'require')
        )
          valid = false;
      });
      const initializerCall = (call: Node) =>
        call?.type === 'CallExpression' &&
        call.callee.type === 'MemberExpression' &&
        call.callee.property.type === 'Identifier' &&
        call.callee.property.value === 'apply' &&
        call.callee.object.type === 'MemberExpression' &&
        sameIdentifier(call.callee.object.object, owner) &&
        call.callee.object.property.type === 'Identifier' &&
        initializerExports.has(call.callee.object.property.value) &&
        call.arguments.length === 2 &&
        call.arguments[0].expression.type === 'ThisExpression' &&
        call.arguments[1].expression.type === 'Identifier' &&
        call.arguments[1].expression.value === 'arguments';
      let returnedCall = false;
      const results: Node[] = [];
      for (const statement of fn.body?.stmts ?? []) {
        if (statement.type === 'VariableDeclaration')
          for (const declaration of statement.declarations) {
            if (initializerCall(declaration.init)) results.push(declaration.id);
          }
        if (
          statement.type === 'ReturnStatement' &&
          (initializerCall(statement.argument) ||
            results.some((result) => sameIdentifier(result, statement.argument)))
        )
          returnedCall = true;
      }
      walk(fn, (child) => {
        if (
          child.type === 'AssignmentExpression' &&
          results.some((result) => sameIdentifier(result, child.left))
        )
          returnedCall = false;
        if (
          child.type === 'UpdateExpression' &&
          results.some((result) => sameIdentifier(result, child.argument))
        )
          returnedCall = false;
      });
      if (!valid || ownerDeclarations !== 1 || ownerWritten || !returnedCall)
        throw new Error('unverified helper initializer forwarder');
      bindings.add(bindingKey(node.id));
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
            guards.add(bindingKey(specifier.local));
        }
      if (node.type === 'FunctionDeclaration')
        walk(node.body, (child) => {
          if (child.type === 'ReturnStatement' && guardRequire(child.argument))
            accessors.add(bindingKey(node.identifier));
        });
    });
    walk(ast, (node) => {
      if (
        node.type === 'VariableDeclarator' &&
        node.id.type === 'Identifier' &&
        node.init?.type === 'CallExpression' &&
        node.init.callee.type === 'Identifier' &&
        accessors.has(bindingKey(node.init.callee))
      )
        namespaces.add(bindingKey(node.id));
    });
    walk(ast, (node) => {
      if (
        node.type === 'VariableDeclarator' &&
        node.id.type === 'Identifier' &&
        node.init?.type === 'MemberExpression' &&
        guardExports.has(memberKey(node.init.property)) &&
        (guardRequire(node.init.object) ||
          (node.init.object.type === 'Identifier' && namespaces.has(bindingKey(node.init.object))))
      )
        guards.add(bindingKey(node.id));
    });
    const guardedBindings = new Map<string, number>();
    walk(ast, (node) => {
      if (
        node.type !== 'CallExpression' ||
        node.callee.type !== 'Identifier' ||
        !guards.has(bindingKey(node.callee)) ||
        node.arguments.length !== 1 ||
        node.arguments[0].expression.type !== 'Identifier' ||
        !bindings.has(bindingKey(node.arguments[0].expression))
      )
        return;
      const binding = bindingKey(node.arguments[0].expression);
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

test('eager imports use actual source Scope0 callers oracle authenticates CJS initializer dataflow', () => {
  const fixture = (forwarder: string) => {
    const outputs = observerFixture(`${forwarder};guard(init);`);
    outputs[2].contents = Buffer.from(
      Buffer.from(outputs[2].contents).toString().replace("import{init}from'./helper.js';", ''),
    );
    return outputs;
  };
  const valid =
    'var init=function(){var m=require("./helper.js");var r=m.init.apply(this,arguments);return r}';
  expect(helperGuardSites(fixture(valid), '/output')).toHaveLength(1);
  for (const decoy of [
    'var init=function(){var unused=require("./helper.js");return other.init.apply(this,arguments)}',
    'var init=function(){var m=require("./helper.js");var other={init(){}};return other.init.apply(this,arguments)}',
    'var init=function(){var m=require("./helper.js");{let m=other;return m.init.apply(this,arguments)}}',
    'var init=function(m){var unused=require("./helper.js");return m.init.apply(this,arguments)}',
    'var init=function(){var m=require("./helper.js");m=other;return m.init.apply(this,arguments)}',
    'var init=function(){var m=require("./helper.js");var r=m.init.apply(this,arguments);r=other;return r}',
  ])
    expect(() => helperGuardSites(fixture(decoy), '/output')).toThrow(
      'unverified helper initializer forwarder',
    );
});
