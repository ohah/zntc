#!/usr/bin/env node
// Keep the production source-to-output identity paths from silently gaining a
// post-transform SemanticAnalyzer. Independent generated AST domains and the
// standalone debug oracle are classified explicitly below.

import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');

function maskZigNonCode(source) {
  const chars = source.split('');
  const maskRange = (start, end) => {
    for (let i = start; i < end; i++) if (chars[i] !== '\n') chars[i] = ' ';
  };

  let i = 0;
  while (i < source.length) {
    const ch = source[i];
    const next = source[i + 1];

    // Zig multiline-string contents start with a backslash pair at the first
    // non-space position on a line. They may contain fake calls and braces.
    if (ch === '\\' && next === '\\') {
      const lineStart = source.lastIndexOf('\n', i - 1) + 1;
      if (/^\s*$/.test(source.slice(lineStart, i))) {
        let end = source.indexOf('\n', i);
        if (end === -1) end = source.length;
        maskRange(i, end);
        i = end;
        continue;
      }
    }

    if (ch === '/' && next === '/') {
      let end = source.indexOf('\n', i);
      if (end === -1) end = source.length;
      maskRange(i, end);
      i = end;
      continue;
    }

    if (ch === '/' && next === '*') {
      const close = source.indexOf('*/', i + 2);
      const end = close === -1 ? source.length : close + 2;
      maskRange(i, end);
      i = end;
      continue;
    }

    if (ch === '"' || ch === "'") {
      const quote = ch;
      const start = i++;
      while (i < source.length) {
        if (source[i] === '\\') {
          i += 2;
          continue;
        }
        if (source[i++] === quote) break;
      }
      maskRange(start, Math.min(i, source.length));
      continue;
    }

    i++;
  }
  return chars.join('');
}

function firstTopLevelTestOffset(code) {
  return /^\s*test\b/m.exec(code)?.index ?? code.length;
}

function analyzerInitSites(source, stopAtTests = true) {
  const code = maskZigNonCode(source);
  const end = stopAtTests ? firstTopLevelTestOffset(code) : code.length;
  const prefix = code.slice(0, end);
  const sites = [];
  const aliases = new Set(['SemanticAnalyzer', 'Analyzer']);
  const declarations = /\bconst\s+([A-Za-z_]\w*)\s*=\s*([^;]+);/g;
  let changed = true;
  while (changed) {
    changed = false;
    for (const match of prefix.matchAll(declarations)) {
      const rhs = match[2].trim().replace(/\s+/g, ' ');
      const isAnalyzerType =
        aliases.has(rhs) ||
        /^@import\([^)]*\)\s*\.\s*SemanticAnalyzer$/.test(rhs) ||
        /(?:^|\.)SemanticAnalyzer$/.test(rhs);
      if (isAnalyzerType && !aliases.has(match[1])) {
        aliases.add(match[1]);
        changed = true;
      }
    }
  }
  const pattern = new RegExp(`\\b(?:${[...aliases].join('|')})\\s*\\.\\s*init\\s*\\(`, 'g');
  for (const match of prefix.matchAll(pattern)) {
    sites.push({
      offset: match.index,
      line: prefix.slice(0, match.index).split('\n').length,
    });
  }
  return { code, sites };
}

function matchingBrace(code, open) {
  let depth = 0;
  for (let i = open; i < code.length; i++) {
    if (code[i] === '{') depth++;
    if (code[i] === '}' && --depth === 0) return i;
  }
  return -1;
}

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}

function auditTranspile(source, label = 'src/transpile.zig') {
  const { code, sites } = analyzerInitSites(source);
  requireCondition(
    sites.length === 2,
    `${label}: expected one source analysis and one debug oracle; found ${sites.length}`,
  );

  const sourceCall = code.indexOf(
    'analyzer_storage = SemanticAnalyzer.init(arena_alloc, &parser.ast);',
  );
  const sourceGraphGate = code.indexOf('requireStandaloneOutputNormalForm(', sourceCall);
  const guard =
    'if (symbol_coverage_env.enabled() and (options.minify_syntax or options.minify_identifiers))';
  const guardStart = code.indexOf(guard);
  const guardOpen = guardStart === -1 ? -1 : code.indexOf('{', guardStart + guard.length);
  const guardClose = guardOpen === -1 ? -1 : matchingBrace(code, guardOpen);
  const oracleCall = code.indexOf('SemanticAnalyzer.init(arena_alloc, transformer.ast);');
  const oracleAnalyze = code.indexOf('post_minify_analyzer.analyze()', oracleCall);
  const oracleReport = code.indexOf('checkPostMinifyWithNativeOwners(', oracleCall);
  const oraclePrint = code.indexOf('post_minify_coverage.printPostMinify(', oracleCall);

  requireCondition(
    sourceCall >= 0 && sourceCall < sourceGraphGate,
    `${label}: source graph must be analyzed before output identity validation`,
  );
  requireCondition(
    guardStart >= 0 && guardClose > guardOpen,
    `${label}: missing bounded debug-oracle guard`,
  );
  requireCondition(
    oracleCall > guardOpen && oracleCall < guardClose,
    `${label}: post-transform analyzer escaped the debug-only oracle guard`,
  );
  requireCondition(
    oracleAnalyze > oracleCall && oracleAnalyze < guardClose,
    `${label}: debug oracle must analyze the output AST inside its guard`,
  );
  requireCondition(
    oracleReport > oracleAnalyze && oracleReport < guardClose,
    `${label}: debug oracle must compare against producer identities`,
  );
  requireCondition(
    oraclePrint > oracleReport && oraclePrint < guardClose,
    `${label}: debug oracle must only publish diagnostics`,
  );
  requireCondition(
    !/transformer\.symbol_ids\s*=\s*post_minify_analyzer\./.test(code.slice(guardOpen, guardClose)),
    `${label}: diagnostic IDs must not replace producer IDs`,
  );
}

function auditSingleInitialAnalysis(source, file, expectedCall) {
  const { code, sites } = analyzerInitSites(source, false);
  requireCondition(
    sites.length === 1,
    `${file}: expected one first analysis for its AST domain; found ${sites.length}`,
  );
  requireCondition(
    code.includes(expectedCall),
    `${file}: expected first-analysis callsite is missing`,
  );
}

function auditPrepass(source, label = 'src/bundler/graph/transform_prepass.zig') {
  const { code, sites } = analyzerInitSites(source);
  requireCondition(
    sites.length === 0,
    `${label}: production transform prepass must edit or reject its input graph, not create an analyzer`,
  );
  requireCondition(
    /pub\s+fn\s+resyncAfterAstMutationForTest\s*\(/.test(code),
    `${label}: test-only oracle wrapper is missing`,
  );
  requireCondition(
    /if\s*\(\s*!@import\s*\(\s*[^)]*\)\s*\.is_test\s*\)\s*@compileError\s*\(/.test(code),
    `${label}: production compile fence for the test oracle is missing`,
  );
}

function tryReject(fn, label) {
  let rejected = false;
  try {
    fn();
  } catch {
    rejected = true;
  }
  requireCondition(rejected, `${label} was not detected`);
}

function selfTest() {
  const transpile =
    `fn transpile() {\n` +
    `  analyzer_storage = SemanticAnalyzer.init(arena_alloc, &parser.ast);\n` +
    `  requireStandaloneOutputNormalForm();\n` +
    `  if (symbol_coverage_env.enabled() and (options.minify_syntax or options.minify_identifiers)) {\n` +
    `    var post_minify_analyzer = SemanticAnalyzer.init(arena_alloc, transformer.ast);\n` +
    `    post_minify_analyzer.analyze() catch return error.SemanticError;\n` +
    `    checkPostMinifyWithNativeOwners();\n` +
    `    post_minify_coverage.printPostMinify(file_path, report);\n` +
    `  }\n` +
    `}\n` +
    `test "test-only analyzer" { var a = SemanticAnalyzer.init(alloc, ast); }\n`;
  auditTranspile(transpile, 'fixture/transpile.zig');
  auditSingleInitialAnalysis(
    'fn parseModule() { var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast); }',
    'fixture/parse_module.zig',
    'SemanticAnalyzer.init(arena_alloc, &parser.ast)',
  );
  auditPrepass(
    'fn runCandidate() {}\n' +
      'pub fn resyncAfterAstMutationForTest() { if (!@import("builtin").is_test) @compileError("test only"); }\n' +
      'test "test helper" { var a = SemanticAnalyzer.init(alloc, ast); }',
  );

  tryReject(
    () =>
      auditTranspile(
        transpile.replace(
          'requireStandaloneOutputNormalForm();',
          'var replacement = SemanticAnalyzer.init(arena_alloc, transformer.ast);',
        ),
      ),
    'new production analyzer in transpile',
  );
  tryReject(
    () =>
      auditTranspile(
        transpile.replace(
          'requireStandaloneOutputNormalForm();',
          'const FreshAnalyzer = SemanticAnalyzer; var replacement = FreshAnalyzer.init(arena_alloc, transformer.ast);',
        ),
      ),
    'aliased production analyzer in transpile',
  );
  tryReject(
    () =>
      auditTranspile(
        transpile.replace(
          'if (symbol_coverage_env.enabled() and (options.minify_syntax or options.minify_identifiers)) {\n    var post_minify_analyzer',
          'var post_minify_analyzer',
        ),
      ),
    'oracle moved outside debug guard',
  );
  tryReject(
    () =>
      auditTranspile(
        transpile.replace(
          'symbol_coverage_env.enabled() and (options.minify_syntax or options.minify_identifiers)',
          'true',
        ),
      ),
    'oracle debug guard weakened',
  );
  tryReject(
    () =>
      auditTranspile(
        transpile.replace(
          'analyzer_storage = SemanticAnalyzer.init(arena_alloc, &parser.ast);',
          '',
        ),
      ),
    'source analyzer removed',
  );
  tryReject(
    () =>
      auditSingleInitialAnalysis(
        'fn parseModule() { var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast); var replacement = Analyzer.init(a, ast); }',
        'fixture/parse_module.zig',
        'SemanticAnalyzer.init(arena_alloc, &parser.ast)',
      ),
    'new parse-module analyzer',
  );
  tryReject(
    () =>
      auditSingleInitialAnalysis(
        'const FreshAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer; fn parseModule() { var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast); var replacement = FreshAnalyzer.init(a, ast); }',
        'fixture/parse_module.zig',
        'SemanticAnalyzer.init(arena_alloc, &parser.ast)',
      ),
    'import-aliased parse-module analyzer',
  );
  tryReject(
    () =>
      auditSingleInitialAnalysis(
        'fn parseJsonModule() { var analyzer = SemanticAnalyzer.init(arena_alloc, &(module.ast.?)); var replacement = Analyzer.init(a, ast); }',
        'fixture/json_module.zig',
        'SemanticAnalyzer.init(arena_alloc, &(module.ast.?))',
      ),
    'extra JSON-domain analyzer',
  );
  tryReject(
    () =>
      auditPrepass(
        'fn runCandidate() { var replacement = SemanticAnalyzer.init(alloc, ast); }\n' +
          'pub fn resyncAfterAstMutationForTest() { if (!@import("builtin").is_test) @compileError("test only"); }\n' +
          'test "test helper" {}',
      ),
    'new production analyzer in prepass',
  );
  tryReject(
    () =>
      auditPrepass(
        'const FreshAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer; fn runCandidate() { var replacement = FreshAnalyzer.init(alloc, ast); }\n' +
          'pub fn resyncAfterAstMutationForTest() { if (!@import("builtin").is_test) @compileError("test only"); }\n' +
          'test "test helper" {}',
      ),
    'aliased production analyzer in prepass',
  );
  tryReject(
    () =>
      auditPrepass(
        'fn runCandidate() {}\n' +
          'pub fn resyncAfterAstMutationForTest() {}\n' +
          'test "test helper" {}',
      ),
    'test-only compile fence removed',
  );
  tryReject(
    () => auditPrepass('fn runCandidate() {}\ntest "test helper" {}'),
    'test-only resync wrapper removed',
  );
  tryReject(
    () =>
      auditPrepass(
        'fn runCandidate() {}\n' +
          'pub fn resyncAfterAstMutationForTest() {}\n' +
          '// if (!@import("builtin").is_test) @compileError("test only");\n' +
          'test "test helper" {}',
      ),
    'commented-out compile fence',
  );
  console.log('semantic reanalysis boundary audit self-test PASS (13 hostile mutations rejected)');
}

if (process.argv.includes('--self-test')) {
  try {
    selfTest();
  } catch (error) {
    console.error(`semantic reanalysis boundary audit self-test FAIL: ${error.message}`);
    process.exit(1);
  }
  process.exit(0);
}

try {
  const transpile = readFileSync(join(root, 'src/transpile.zig'), 'utf8');
  const parseModule = readFileSync(join(root, 'src/bundler/graph/parse_module.zig'), 'utf8');
  const jsonModule = readFileSync(join(root, 'src/bundler/graph/json_module.zig'), 'utf8');
  const prepass = readFileSync(join(root, 'src/bundler/graph/transform_prepass.zig'), 'utf8');

  auditTranspile(transpile);
  auditSingleInitialAnalysis(
    parseModule,
    'src/bundler/graph/parse_module.zig',
    'SemanticAnalyzer.init(arena_alloc, &parser.ast)',
  );
  auditSingleInitialAnalysis(
    jsonModule,
    'src/bundler/graph/json_module.zig',
    'SemanticAnalyzer.init(arena_alloc, &(module.ast.?))',
  );
  auditPrepass(prepass);
  console.log('semantic reanalysis boundary audit PASS');
} catch (error) {
  console.error(`semantic reanalysis boundary audit FAIL: ${error.message}`);
  process.exit(1);
}
