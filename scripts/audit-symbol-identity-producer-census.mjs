#!/usr/bin/env node
// Pin the bounded AST binding-constructor inventory documented in
// docs/SYMBOL_IDENTITY_PRODUCER_CENSUS.md. This counts producer expressions;
// it does not claim that the full #4819/#6193 migration is complete.

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(import.meta.dirname, '..');
const scanRoot = join(root, 'src', 'transformer');
const constructors = [
  'makeSyntheticBinding',
  'makeExactSyntheticBinding',
  'makeExactSyntheticBindingFromSpan',
  'createSyntheticTempBinding',
  'makeUsingBinding',
  'createSyntheticTempBindingWithIdentity',
];

// These functions are reachable only from inline test blocks, so their bodies
// are not production producer sites. Keep this list path-scoped and pinned:
// an unfamiliar helper is counted and changes the fingerprint for review.
const testOnlyHelpers = new Set([
  'src/transformer/es2015_generator.zig::checkGeneratorAssignmentBindingIdentity',
  'src/transformer/es2015_generator.zig::checkGeneratorHoistProducerUsesExactBindingHandle',
  'src/transformer/native_constructor_function_cells.zig::runControl',
]);

// Constructor implementations and their internal delegation do not represent
// another producer. makeUsingBinding is a selector wrapper with the same rule.
const constructorHelpers = new Set(constructors);

const expected = {
  // Base-plus-feature source label, not a claim that the base commit contains it.
  revision: '2db55b3888a9365357242072348c9df8d05a11e9+lazy-iterator-reference-consumers',
  total: 142,
  files: 45,
  functions: 92,
  byConstructor: {
    makeSyntheticBinding: 54,
    makeExactSyntheticBinding: 43,
    makeExactSyntheticBindingFromSpan: 30,
    createSyntheticTempBinding: 9,
    makeUsingBinding: 4,
    createSyntheticTempBindingWithIdentity: 2,
  },
  fingerprint: '6191ff81358f3e74d6ab1fdbfe83d5446c6b7cb8c0288382d278dc9fcedd8194',
};

const historicalBaseline = {
  revision: '7346fc2cb48980257f9fc5a8625dc627eb7f0768',
  total: 112,
  files: 35,
  functions: 70,
  byConstructor: {
    makeSyntheticBinding: 50,
    makeExactSyntheticBinding: 26,
    makeExactSyntheticBindingFromSpan: 20,
    createSyntheticTempBinding: 10,
    makeUsingBinding: 4,
    createSyntheticTempBindingWithIdentity: 2,
  },
};

// Keep offsets stable so masks, regex matches, and original-source excerpts
// refer to the same positions. Zig source uses UTF-16 offsets in JavaScript.
function maskCommentsAndStrings(source) {
  const chars = source.split('');
  let i = 0;
  let lineStart = true;
  let blockDepth = 0;

  while (i < chars.length) {
    if (blockDepth > 0) {
      if (chars[i] === '/' && chars[i + 1] === '*') {
        chars[i] = chars[i + 1] = ' ';
        blockDepth++;
        i += 2;
        continue;
      }
      if (chars[i] === '*' && chars[i + 1] === '/') {
        chars[i] = chars[i + 1] = ' ';
        blockDepth--;
        i += 2;
        continue;
      }
      if (chars[i] !== '\n') chars[i] = ' ';
      else lineStart = true;
      i++;
      continue;
    }

    if (lineStart) {
      let first = i;
      while (chars[first] === ' ' || chars[first] === '\t' || chars[first] === '\r') first++;
      if (chars[first] === '\\' && chars[first + 1] === '\\') {
        while (i < chars.length && chars[i] !== '\n') chars[i++] = ' ';
        continue;
      }
      lineStart = false;
    }

    if (chars[i] === '\n') {
      lineStart = true;
      i++;
      continue;
    }
    if (chars[i] === '/' && chars[i + 1] === '/') {
      while (i < chars.length && chars[i] !== '\n') chars[i++] = ' ';
      continue;
    }
    if (chars[i] === '/' && chars[i + 1] === '*') {
      chars[i] = chars[i + 1] = ' ';
      blockDepth = 1;
      i += 2;
      continue;
    }
    if (chars[i] === '"' || chars[i] === "'") {
      const quote = chars[i];
      chars[i++] = ' ';
      while (i < chars.length) {
        if (chars[i] === '\\') {
          chars[i++] = ' ';
          if (i < chars.length && chars[i] !== '\n') chars[i++] = ' ';
          continue;
        }
        const current = chars[i];
        chars[i++] = current === '\n' ? '\n' : ' ';
        if (current === quote) break;
      }
      continue;
    }
    i++;
  }
  return chars.join('');
}

function matchingPairs(code, open, close) {
  const stack = [];
  const pairs = new Map();
  for (let i = 0; i < code.length; i++) {
    if (code[i] === open) stack.push(i);
    else if (code[i] === close) {
      const start = stack.pop();
      if (start !== undefined) pairs.set(start, i);
    }
  }
  return pairs;
}

function maskInlineTests(source) {
  const chars = source.split('');
  const code = maskCommentsAndStrings(source);
  const tests = /\btest\s*\{/g;
  let match;

  while ((match = tests.exec(code)) !== null) {
    const open = code.indexOf('{', match.index);
    let depth = 0;
    let end = -1;
    for (let i = open; i < code.length; i++) {
      if (code[i] === '{') depth++;
      else if (code[i] === '}' && --depth === 0) {
        end = i + 1;
        break;
      }
    }
    if (end < 0) throw new Error('unterminated inline test block');
    for (let i = match.index; i < end; i++) chars[i] = ' ';
    tests.lastIndex = end;
  }
  return chars.join('');
}

function functionRanges(code, braces, parens) {
  const ranges = [];
  const declarations = /\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
  let match;

  while ((match = declarations.exec(code)) !== null) {
    const paramsOpen = code.indexOf('(', match.index);
    const paramsClose = parens.get(paramsOpen);
    if (paramsClose === undefined) throw new Error('unmatched function parameter list');

    let bodyOpen = -1;
    for (let i = paramsClose + 1; i < code.length; i++) {
      if (code[i] === ';') break;
      if (code[i] !== '{') continue;
      const close = braces.get(i);
      if (close === undefined) throw new Error('unmatched function or return-type brace');
      let after = close + 1;
      while (/\s/.test(code[after] ?? '')) after++;
      // Anonymous struct/union/enum return types end before the function body.
      if (code[after] === '{') continue;
      bodyOpen = i;
      ranges.push({ name: match[1], start: bodyOpen, end: close + 1 });
      break;
    }
    if (bodyOpen < 0) throw new Error('function declaration has no body');
  }
  return ranges;
}

function enclosingFunction(ranges, offset) {
  const matches = ranges.filter((range) => range.start <= offset && offset < range.end);
  matches.sort((a, b) => a.end - a.start - (b.end - b.start));
  return matches[0]?.name ?? '<top>';
}

function invocationEnd(code, open) {
  let depth = 0;
  for (let i = open; i < code.length; i++) {
    if (code[i] === '(') depth++;
    else if (code[i] === ')' && --depth === 0) return i + 1;
  }
  throw new Error('unterminated constructor call');
}

function scanSource(source, rel) {
  if (rel.endsWith('_test.zig')) return [];

  const sourceWithoutTests = maskInlineTests(source);
  const code = maskCommentsAndStrings(sourceWithoutTests);
  const braces = matchingPairs(code, '{', '}');
  const parens = matchingPairs(code, '(', ')');
  const ranges = functionRanges(code, braces, parens);
  const callPattern = new RegExp('\\b(?:' + constructors.join('|') + ')\\s*\\(', 'g');
  const calls = [];
  let match;

  while ((match = callPattern.exec(code)) !== null) {
    const name = match[0].match(/^[A-Za-z_][A-Za-z0-9_]*/)[0];
    if (/\bfn\s+$/.test(code.slice(Math.max(0, match.index - 16), match.index))) continue;
    const fn = enclosingFunction(ranges, match.index);
    if (constructorHelpers.has(fn) || testOnlyHelpers.has(rel + '::' + fn)) continue;

    const open = code.indexOf('(', match.index);
    const end = invocationEnd(code, open);
    const expression = source.slice(match.index, end).replace(/\s+/gu, ' ').trim();
    const line = source.slice(0, match.index).split('\n').length;
    calls.push({ rel, fn, name, expression, line });
  }
  return calls;
}

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path, out);
    else if (name.endsWith('.zig')) out.push(path);
  }
  return out;
}

function scanRevision(revision) {
  const files = execFileSync('git', ['ls-tree', '-r', '--name-only', revision, 'src/transformer'], {
    cwd: root,
    encoding: 'utf8',
  })
    .trim()
    .split('\n')
    .filter((path) => path.endsWith('.zig'));
  const calls = [];
  for (const rel of files) {
    const source = execFileSync('git', ['show', revision + ':' + rel], {
      cwd: root,
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024,
    });
    calls.push(...scanSource(source, rel));
  }
  return calls;
}

function census(calls) {
  const byConstructor = Object.fromEntries(constructors.map((name) => [name, 0]));
  for (const call of calls) byConstructor[call.name]++;
  const functionKeys = new Set(calls.map((call) => call.rel + '::' + call.fn));
  const rows = calls
    .map((call) => [call.rel, call.fn, call.name, call.expression].join('\t'))
    .sort();
  const fingerprint = createHash('sha256').update(rows.join('\n')).digest('hex');
  return {
    total: calls.length,
    files: new Set(calls.map((call) => call.rel)).size,
    functions: functionKeys.size,
    byConstructor,
    fingerprint,
  };
}

function groupedCounts(calls) {
  const groups = new Map();
  for (const call of calls) {
    const key = [call.rel, call.fn, call.name].join('::');
    groups.set(key, (groups.get(key) ?? 0) + 1);
  }
  return groups;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function runSelfTest() {
  const path = 'src/transformer/native_constructor_function_cells.zig';
  const fixture = [
    'const Fixture = struct {',
    '  fn makeSyntheticBinding(self: anytype, name: []const u8) !u32 {',
    '    return makeExactSyntheticBinding(self, name);',
    '  }',
    '  fn production(self: anytype) !void {',
    '    const a = try makeExactSyntheticBinding(',
    '      self,',
    '      "live",',
    '    );',
    '    const b = try makeSyntheticBinding(self, "also_live");',
    '    _ = .{ a, b };',
    '  }',
    '  fn runControl(self: anytype) !void {',
    '    _ = try makeExactSyntheticBinding(self, "test_only_helper");',
    '  }',
    '  test "nested fixture" {',
    '    if (true) {',
    '      _ = try makeExactSyntheticBinding(self, "inline_test");',
    '    }',
    '    const brace = "}";',
    '  }',
    '};',
    '// makeSyntheticBinding(self, "comment");',
    'const text = "makeExactSyntheticBinding(self, \\"string\\")";',
  ].join('\n');

  const baseline = census(scanSource(fixture, path));
  assert(baseline.total === 2, 'test blocks, helper wrappers, or test-only helpers leaked');
  assert(baseline.byConstructor.makeExactSyntheticBinding === 1, 'exact constructor was missed');
  assert(
    baseline.byConstructor.makeSyntheticBinding === 1,
    'multiline-safe constructor was missed',
  );

  const added = fixture.replace(
    '    _ = .{ a, b };',
    '    _ = .{ a, b };\n    _ = try createSyntheticTempBinding(self, "mutant");',
  );
  const addedCensus = census(scanSource(added, path));
  assert(addedCensus.total === 3, 'production call mutation was not detected');
  assert(
    addedCensus.fingerprint !== baseline.fingerprint,
    'production call mutation did not change the callsite fingerprint',
  );

  const removed = fixture.replace(
    '    const b = try makeSyntheticBinding(self, "also_live");\n',
    '',
  );
  assert(
    census(scanSource(removed, path)).total === 1,
    'removed production call was still counted',
  );

  const unfamiliarHelper = fixture.replace(
    '  test "nested fixture" {',
    '  fn newUnreviewedTestHelper(self: anytype) !void { _ = try makeUsingBinding(self, "helper"); }\n  test "nested fixture" {',
  );
  assert(
    census(scanSource(unfamiliarHelper, path)).total === 3,
    'an unclassified helper did not force a census change',
  );
  console.log('symbol identity producer census self-test PASS (4 hostile mutations checked)');
}

function main() {
  if (process.argv.includes('--self-test')) {
    runSelfTest();
    return;
  }
  runSelfTest();

  if (
    process.argv.includes('--verify-historical-baseline') ||
    process.argv.includes('--compare-historical-baseline')
  ) {
    const oldCalls = scanRevision(historicalBaseline.revision);
    const old = census(oldCalls);
    const oldErrors = [];
    for (const key of ['total', 'files', 'functions']) {
      if (old[key] !== historicalBaseline[key])
        oldErrors.push(key + ': expected ' + historicalBaseline[key] + ', actual ' + old[key]);
    }
    for (const name of constructors) {
      if (old.byConstructor[name] !== historicalBaseline.byConstructor[name])
        oldErrors.push(
          name +
            ': expected ' +
            historicalBaseline.byConstructor[name] +
            ', actual ' +
            old.byConstructor[name],
        );
    }
    if (oldErrors.length > 0) {
      console.error('historical census calibration failed:');
      for (const failure of oldErrors) console.error('  ' + failure);
      process.exit(1);
    }
    console.log(
      'historical census calibration PASS (' +
        old.total +
        ' callsites, ' +
        old.files +
        ' files, ' +
        old.functions +
        ' functions)',
    );
    if (!process.argv.includes('--compare-historical-baseline')) return;

    const currentCalls = walk(scanRoot)
      .map((file) => scanSource(readFileSync(file, 'utf8'), relative(root, file)))
      .flat();
    const oldGroups = groupedCounts(oldCalls);
    const currentGroups = groupedCounts(currentCalls);
    for (const key of [...new Set([...oldGroups.keys(), ...currentGroups.keys()])].sort()) {
      const delta = (currentGroups.get(key) ?? 0) - (oldGroups.get(key) ?? 0);
      if (delta !== 0) console.log((delta > 0 ? '+' : '') + delta + ' ' + key);
    }
    return;
  }

  const calls = walk(scanRoot)
    .map((file) => scanSource(readFileSync(file, 'utf8'), relative(root, file)))
    .flat();
  const actual = census(calls);
  const snapshot = {
    revision: expected.revision,
    total: actual.total,
    files: actual.files,
    functions: actual.functions,
    byConstructor: actual.byConstructor,
    fingerprint: actual.fingerprint,
  };

  if (process.argv.includes('--print-snapshot')) {
    console.log(JSON.stringify(snapshot, null, 2));
    return;
  }

  const mismatches = [];
  for (const key of ['total', 'files', 'functions', 'fingerprint']) {
    if (actual[key] !== expected[key])
      mismatches.push(key + ': expected ' + expected[key] + ', actual ' + actual[key]);
  }
  for (const name of constructors) {
    if (actual.byConstructor[name] !== expected.byConstructor[name])
      mismatches.push(
        name +
          ': expected ' +
          expected.byConstructor[name] +
          ', actual ' +
          actual.byConstructor[name],
      );
  }
  if (mismatches.length > 0) {
    console.error(
      'SymbolId producer census changed; review each constructor call and update the pinned snapshot:',
    );
    for (const mismatch of mismatches) console.error('  ' + mismatch);
    process.exit(1);
  }
  console.log(
    'symbol identity producer census OK (' +
      actual.total +
      ' callsites, fingerprint ' +
      actual.fingerprint +
      ')',
  );
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : null;
if (invokedPath === import.meta.url) main();
