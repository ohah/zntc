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

// CommonJS forwarders require a free host `require`. Collect only bindings
// owned by the Program execution frame; never inspect nested function/class
// execution frames. Hoisted var/function declarations under control flow count.
function rootBindingNames(program: Node): Set<string> {
  const names = new Set<string>();
  const pattern = (node: Node | null | undefined, target = names): void => {
    if (!node) return;
    switch (node.type) {
      case 'Identifier':
        target.add(node.value);
        break;
      case 'ArrayPattern':
        for (const item of node.elements) pattern(item, target);
        break;
      case 'ObjectPattern':
        for (const property of node.properties) {
          if (property.type === 'KeyValuePatternProperty') pattern(property.value, target);
          else if (property.type === 'AssignmentPatternProperty') pattern(property.key, target);
          else if (property.type === 'RestElement') pattern(property.argument, target);
        }
        break;
      case 'RestElement':
        pattern(node.argument, target);
        break;
      case 'AssignmentPattern':
        pattern(node.left, target);
        break;
    }
  };
  const moduleSyntax = program.body.some(
    (node: Node) => node.type === 'ImportDeclaration' || node.type.startsWith('Export'),
  );
  let strict = moduleSyntax;
  for (const statement of program.body) {
    if (statement.type !== 'ExpressionStatement' || statement.expression.type !== 'StringLiteral')
      break;
    if (statement.expression.raw === '"use strict"' || statement.expression.raw === "'use strict'")
      strict = true;
  }
  const lexicalNames = (statements: Node[]): Set<string> => {
    const local = new Set<string>();
    for (const statement of statements) {
      if (statement.type === 'VariableDeclaration' && statement.kind !== 'var')
        for (const declaration of statement.declarations) pattern(declaration.id, local);
      if (
        statement.type === 'ClassDeclaration' ||
        (strict && statement.type === 'FunctionDeclaration')
      )
        pattern(statement.identifier, local);
    }
    return local;
  };
  const write = (target: Node, shadows: readonly Set<string>[]) => {
    const targets = new Set<string>();
    pattern(target, targets);
    for (const name of targets) if (!shadows.some((scope) => scope.has(name))) names.add(name);
  };
  const scan = (node: any, direct: boolean, shadows: readonly Set<string>[]): void => {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) {
      for (const child of node) scan(child, direct, shadows);
      return;
    }
    if (node.type === 'FunctionDeclaration') {
      if (direct || !strict) pattern(node.identifier);
      return;
    }
    if (node.type === 'ClassDeclaration') {
      if (direct) pattern(node.identifier);
      return;
    }
    if (
      [
        'FunctionExpression',
        'ArrowFunctionExpression',
        'ClassExpression',
        'MethodProperty',
        'GetterProperty',
        'SetterProperty',
      ].includes(node.type)
    )
      return;
    if (node.type === 'ImportDeclaration') {
      for (const specifier of node.specifiers) pattern(specifier.local);
      return;
    }
    if (node.type === 'ExportDeclaration') {
      scan(node.declaration, direct, shadows);
      return;
    }
    if (node.type === 'ExportDefaultDeclaration') {
      if (direct) pattern(node.decl.identifier);
      return;
    }
    if (node.type === 'BlockStatement') {
      scan(node.stmts, false, [...shadows, lexicalNames(node.stmts)]);
      return;
    }
    if (node.type === 'CatchClause') {
      const local = new Set<string>();
      pattern(node.param, local);
      scan(node.body, false, [...shadows, local]);
      return;
    }
    if (['ForStatement', 'ForOfStatement', 'ForInStatement'].includes(node.type)) {
      const declaration = node.type === 'ForStatement' ? node.init : node.left;
      const local =
        declaration?.type === 'VariableDeclaration' && declaration.kind !== 'var'
          ? lexicalNames([declaration])
          : new Set<string>();
      const loopShadows = [...shadows, local];
      if (node.type !== 'ForStatement' && node.left.type !== 'VariableDeclaration')
        write(node.left, loopShadows);
      for (const [key, value] of Object.entries(node))
        if (key !== 'span') scan(value, false, loopShadows);
      return;
    }
    if (node.type === 'SwitchStatement') {
      scan(node.discriminant, false, shadows);
      const local = lexicalNames(node.cases.flatMap((item: Node) => item.consequent));
      scan(node.cases, false, [...shadows, local]);
      return;
    }
    if (node.type === 'VariableDeclaration') {
      for (const declaration of node.declarations) {
        if (direct || node.kind === 'var') pattern(declaration.id);
        scan(declaration.id, false, shadows);
        scan(declaration.init, false, shadows);
      }
      return;
    }
    if (node.type === 'AssignmentExpression') write(node.left, shadows);
    if (node.type === 'UpdateExpression') write(node.argument, shadows);
    for (const [key, value] of Object.entries(node))
      if (key !== 'span') scan(value, false, shadows);
  };
  for (const statement of program.body) scan(statement, true, []);

  return names;
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
  const providerExports = new Set(provider.exports);
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
      for (const specifier of node.specifiers)
        if (specifier.type === 'ExportSpecifier')
          providerExports.add(specifier.exported?.value ?? specifier.orig.value);
    if (
      node.type === 'AssignmentExpression' &&
      node.left.type === 'MemberExpression' &&
      node.left.object.type === 'Identifier' &&
      node.left.object.value === 'exports' &&
      node.left.property.type === 'Identifier'
    )
      providerExports.add(node.left.property.value);
    if (
      node.type === 'CallExpression' &&
      node.arguments[0]?.expression.type === 'Identifier' &&
      node.arguments[0].expression.value === 'exports' &&
      node.arguments[1]?.expression.type === 'StringLiteral'
    )
      providerExports.add(node.arguments[1].expression.value);
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
    const rootNames = rootBindingNames(ast);
    const declarations = new Map<string, Node>();
    const directForwarders = new Set<Node>();
    for (const statement of ast.body)
      if (statement.type === 'VariableDeclaration')
        for (const declaration of statement.declarations) {
          if (declaration.id.type === 'Identifier')
            declarations.set(bindingKey(declaration.id), declaration);
          if (declaration.init?.type === 'FunctionExpression') directForwarders.add(declaration);
        }

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
      if (!mentionsRequire) return;
      if (!mentionsInitializer) throw new Error('unverified helper initializer forwarder');
      // This is a closed grammar for the actual chunk writer, not a general
      // dataflow analysis: require; [namespace refresh]; init; [value refresh];
      // terminal return. Every statement must be consumed in that order.
      const reject = () => {
        throw new Error('unverified helper initializer forwarder');
      };
      if (
        !directForwarders.has(node) ||
        fn.identifier ||
        fn.async ||
        fn.generator ||
        fn.params.length !== 0
      )
        reject();
      const statements: Node[] = fn.body?.stmts ?? [];
      const singleDeclaration = (statement: Node) =>
        statement?.type === 'VariableDeclaration' &&
        statement.declarations.length === 1 &&
        statement.declarations[0].id.type === 'Identifier'
          ? statement.declarations[0]
          : undefined;
      const required = singleDeclaration(statements[0]);
      const owner = required?.id;
      if (
        !owner ||
        owner.value === 'require' ||
        owner.value === 'arguments' ||
        !actualRequire(required.init) ||
        rootNames.has('require')
      )
        reject();
      const propertyName = (property: Node) =>
        property.type === 'Identifier'
          ? property.value
          : property.type === 'Computed' && property.expression.type === 'StringLiteral'
            ? property.expression.value
            : undefined;
      const providerMember = (value: Node) =>
        value?.type === 'MemberExpression' &&
        sameIdentifier(value.object, owner) &&
        providerExports.has(propertyName(value.property));
      const initializerCall = (call: Node) =>
        call?.type === 'CallExpression' &&
        call.callee.type === 'MemberExpression' &&
        propertyName(call.callee.property) === 'apply' &&
        providerMember(call.callee.object) &&
        initializerExports.has(propertyName(call.callee.object.property)) &&
        call.arguments.length === 2 &&
        call.arguments[0].expression.type === 'ThisExpression' &&
        call.arguments[1].expression.type === 'Identifier' &&
        call.arguments[1].expression.value === 'arguments';
      const refreshed = new Set<string>();
      const refresh = (statement: Node, beforeInitialization: boolean) => {
        if (
          statement?.type !== 'ExpressionStatement' ||
          statement.expression.type !== 'AssignmentExpression'
        )
          return false;
        const assignment = statement.expression;
        if (
          assignment.operator !== '=' ||
          assignment.left.type !== 'Identifier' ||
          !providerMember(assignment.right)
        )
          return false;
        const key = bindingKey(assignment.left);
        const alias = declarations.get(key);
        if (!alias || refreshed.has(key)) return false;
        if (beforeInitialization) {
          // The namespace refresh updates the exact Program binding which was
          // initialized from this physical provider's same exported property.
          if (
            alias.init?.type !== 'MemberExpression' ||
            !actualRequire(alias.init.object) ||
            propertyName(alias.init.property) !== propertyName(assignment.right.property)
          )
            return false;
        } else if (alias.init != null) return false;
        refreshed.add(key);
        return true;
      };
      let cursor = 1;
      if (refresh(statements[cursor], true)) cursor++;
      const terminal = statements.at(-1);
      if (terminal?.type !== 'ReturnStatement') reject();
      if (statements[cursor] === terminal && initializerCall(terminal.argument)) cursor++;
      else {
        const result = singleDeclaration(statements[cursor]);
        if (!result || !initializerCall(result.init) || sameIdentifier(result.id, owner)) reject();
        cursor++;
        while (cursor < statements.length - 1 && refresh(statements[cursor], false)) cursor++;
        if (statements[cursor] !== terminal || !sameIdentifier(terminal.argument, result.id))
          reject();
        cursor++;
      }
      if (cursor !== statements.length) reject();
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
  expect(
    helperGuardSites(
      fixture(
        'var init=function(){var m=require("./helper.js");return m.init.apply(this,arguments)}',
      ),
      '/output',
    ),
  ).toHaveLength(1);
  const refreshFixture = fixture(
    'var ns=require("./helper.js").ns;var value;var init=function(){var m=require("./helper.js");ns=m.ns;var r=m.init.apply(this,arguments);value=m.value;return r}',
  );
  refreshFixture[0].contents = Buffer.from(
    'var init=wrap({body(){}}),ns={},value;export{init,ns,value};',
  );
  expect(helperGuardSites(refreshFixture, '/output')).toHaveLength(1);
  for (const decoy of [
    'var init=function(){var m=require("./helper.js");if(skip)return other.init.apply(this,arguments);return m.init.apply(this,arguments)}',
    'var init=function(){var m=require("./helper.js");if(skip)return m.init.apply(this,arguments);else return m.init.apply(this,arguments)}',
    'var init=function(){var m=require("./helper.js");while(skip){}return m.init.apply(this,arguments)}',
    'var init=function(){var m=require("./helper.js");try{return m.init.apply(this,arguments)}catch(e){throw e}}',
    'var init=function(){var m=require("./helper.js");{return m.init.apply(this,arguments)}}',
    'var init=function(){var m=require("./helper.js");return m.init.apply(this,arguments);other()}',
    'var init=function(){var m=require("./helper.js");other();return m.init.apply(this,arguments)}',
    'var init=function(){var m=require("./helper.js");var unused=1;return m.init.apply(this,arguments)}',
    'var init=function(){var unused=require("./helper.js");return other()}',
    'var init=function named(){var m=require("./helper.js");return m.init.apply(this,arguments)}',
    'var init=async function(){var m=require("./helper.js");return m.init.apply(this,arguments)}',
    'var init=function*(){var m=require("./helper.js");return m.init.apply(this,arguments)}',
    'var outer=function(){var init=function(){var m=require("./helper.js");return m.init.apply(this,arguments)};guard(init)}',
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
  for (const shadow of [
    'function require(path){return{init(){}}}',
    'class require{}',
    'import require from "foreign";',
    'import * as require from "foreign";',
    'import {x as require} from "foreign";',
    'export function require(){}',
    'export class require{}',
    'export default function require(){}',
    'export default class require{}',
    'export const require=foreign;',
    'const [require]=foreign;',
    'const [,require=foreign]=foreign;',
    'const {x:require}=foreign;',
    'const {require=foreign}=foreign;',
    'const {...require}=foreign;',
    'const {x:[...require]}=foreign;',
    'if(false){var require=foreign}',
    'for(var require of foreign){}',
    'try{}finally{var require}',
    'require=foreign;',
    'require++;',
    'for(require of foreign){}',
    'for(require in foreign){}',
    'var x=(require=foreign);',
    'var x=(require++);',
    'var [x=(require=foreign)]=foreign;',
    '({x:require}=foreign);',
    '[require]=foreign;',
    '({x:[...require]}=foreign);',
  ])
    expect(() => helperGuardSites(fixture(`${shadow};${valid}`), '/output')).toThrow(
      'unverified helper initializer forwarder',
    );
  // A different execution frame's bindings do not shadow CommonJS require.
  for (const nested of [
    'function other(){function require(){}}',
    'var other=function(require){}',
    'class Other{method(require){}}',
    'if(false){class require{}}',
    "'use strict';if(false){function require(){}}",
    '{let require=foreign;require=other}',
    'for(let require of foreign){require=other}',
    'for(let require=foreign;condition;require++){require=other}',
    'try{}catch(require){require=other}',
    'switch(value){case 1:let require;require=other}',
    'var other={method(){require=foreign}}',
    'function other(){require=foreign}',
    'var other=function(){require++}',
    'class Other{method(){require=foreign}}',
  ])
    expect(helperGuardSites(fixture(`${nested};${valid}`), '/output')).toHaveLength(1);
  const sloppy = fixture(`if(true){function require(){}};${valid}`);
  sloppy[2].contents = Buffer.from(
    Buffer.from(sloppy[2].contents)
      .toString()
      .replace("import{guard}from'./guard.js';", "var guard=require('./guard.js').guard;"),
  );
  expect(() => helperGuardSites(sloppy, '/output')).toThrow(
    'unverified helper initializer forwarder',
  );
  const strictCjs = fixture(valid);
  strictCjs[2].contents = Buffer.from(
    `"use strict";var guard=require('./guard.js').guard;if(false){function require(){}};${valid};guard(init);`,
  );
  expect(helperGuardSites(strictCjs, '/output')).toHaveLength(1);
  const escapedDirective = fixture(valid);
  escapedDirective[2].contents = Buffer.from(
    String.raw`"use\x20strict";var guard=require('./guard.js').guard;if(true){function require(){}};${valid};guard(init);`,
  );
  expect(() => helperGuardSites(escapedDirective, '/output')).toThrow(
    'unverified helper initializer forwarder',
  );
});
