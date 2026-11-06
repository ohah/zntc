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

function topLevelTestRanges(code) {
  const ranges = [];
  for (const match of code.matchAll(/^[\t ]*test\b/gm)) {
    const open = code.indexOf('{', match.index + match[0].length);
    if (open === -1) continue;
    const close = matchingBrace(code, open);
    if (close === -1) continue;
    ranges.push([match.index, close + 1]);
  }
  return ranges;
}

function containingRange(ranges, offset) {
  return ranges.find(([start, end]) => offset >= start && offset < end) ?? null;
}

function analyzerInitSites(source, includeTestBodies = false) {
  const code = maskZigNonCode(source);
  const testRanges = topLevelTestRanges(code);
  const sites = [];
  const aliases = new Set(['SemanticAnalyzer', 'Analyzer']);
  const declarations = /\bconst\s+([A-Za-z_]\w*)\s*=\s*([^;]+);/g;
  let changed = true;
  while (changed) {
    changed = false;
    for (const match of code.matchAll(declarations)) {
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
  for (const match of code.matchAll(pattern)) {
    if (!includeTestBodies && containingRange(testRanges, match.index)) continue;
    sites.push({
      offset: match.index,
      line: code.slice(0, match.index).split('\n').length,
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

function functionBody(code, name, label) {
  const declaration = new RegExp(`\\b(?:pub\\s+)?fn\\s+${name}\\s*\\(`).exec(code);
  requireCondition(declaration, `${label}: function ${name} is missing`);
  const open = code.indexOf('{', declaration.index + declaration[0].length);
  const close = open === -1 ? -1 : matchingBrace(code, open);
  requireCondition(close > open, `${label}: function ${name} body is malformed`);
  return {
    declaration: declaration.index,
    start: open + 1,
    end: close,
    body: code.slice(open + 1, close),
  };
}

function matchingDelimiter(code, open, openChar, closeChar) {
  let depth = 0;
  for (let i = open; i < code.length; i++) {
    if (code[i] === openChar) depth++;
    if (code[i] === closeChar && --depth === 0) return i;
  }
  return -1;
}

function skipWhitespace(code, start) {
  while (start < code.length && /\s/.test(code[start])) start++;
  return start;
}

function statementEnd(code, start) {
  const bodyStart = skipWhitespace(code, start);
  if (code[bodyStart] === '{') {
    const close = matchingBrace(code, bodyStart);
    return close < 0 ? code.length : close + 1;
  }
  if (/^if\b/.test(code.slice(bodyStart))) return ifStatementEnd(code, bodyStart);

  let parens = 0;
  let brackets = 0;
  let braces = 0;
  for (let i = bodyStart; i < code.length; i++) {
    switch (code[i]) {
      case '(':
        parens++;
        break;
      case ')':
        parens--;
        break;
      case '[':
        brackets++;
        break;
      case ']':
        brackets--;
        break;
      case '{':
        braces++;
        break;
      case '}':
        if (braces === 0) return i;
        braces--;
        break;
      case ';':
        if (parens === 0 && brackets === 0 && braces === 0) return i + 1;
        break;
    }
  }
  return code.length;
}

function ifStatementEnd(code, start) {
  const conditionOpen = code.indexOf('(', start + 2);
  const conditionClose = conditionOpen < 0 ? -1 : matchingDelimiter(code, conditionOpen, '(', ')');
  if (conditionClose < 0) return code.length;

  let bodyStart = skipWhitespace(code, conditionClose + 1);
  if (code[bodyStart] === '|') {
    const payloadClose = code.indexOf('|', bodyStart + 1);
    bodyStart = payloadClose < 0 ? code.length : skipWhitespace(code, payloadClose + 1);
  }
  const bodyEnd = statementEnd(code, bodyStart);
  const elseStart = skipWhitespace(code, bodyEnd);
  if (!/^else\b/.test(code.slice(elseStart))) return bodyEnd;
  return statementEnd(code, elseStart + 'else'.length);
}

function coverageDiagnosticGuardRanges(code) {
  const ranges = [];
  for (const match of code.matchAll(/\bif\s*\(/g)) {
    const conditionOpen = code.indexOf('(', match.index);
    const conditionClose = matchingDelimiter(code, conditionOpen, '(', ')');
    if (conditionClose < 0) continue;
    const condition = code.slice(conditionOpen + 1, conditionClose);
    if (!/\b(?:symbol_coverage_env|synthetic_coverage_env)\b/.test(condition)) continue;

    let bodyStart = skipWhitespace(code, conditionClose + 1);
    if (code[bodyStart] === '|') {
      const payloadClose = code.indexOf('|', bodyStart + 1);
      bodyStart = payloadClose < 0 ? code.length : skipWhitespace(code, payloadClose + 1);
    }
    const end = ifStatementEnd(code, match.index);
    if (end > bodyStart) ranges.push([bodyStart, end]);
  }
  return ranges;
}

// Zig test blocks can be interleaved with production declarations and test
// helpers can live outside the blocks. Follow same-file function calls from
// production roots instead of treating everything after the first `test` as
// either production or test-only.
function productionFunctionDefinitions(code) {
  const testRanges = topLevelTestRanges(code);
  const definitions = new Map();
  const declarationPattern = /\b(?:pub\s+)?fn\s+([A-Za-z_]\w*)\s*\(/g;
  for (const declaration of code.matchAll(declarationPattern)) {
    if (containingRange(testRanges, declaration.index)) continue;
    const open = code.indexOf('{', declaration.index + declaration[0].length);
    if (open === -1) continue;
    const close = matchingBrace(code, open);
    if (close === -1) continue;
    const rows = definitions.get(declaration[1]) ?? [];
    rows.push({ start: open + 1, end: close, body: code.slice(open + 1, close) });
    definitions.set(declaration[1], rows);
  }
  return definitions;
}

function analyzerSitesReachableFrom(source, roots, label) {
  const code = maskZigNonCode(source);
  const definitions = productionFunctionDefinitions(code);
  const allSites = analyzerInitSites(source, true).sites;
  const pending = [...roots];
  const visited = new Set();
  const ranges = [];
  while (pending.length > 0) {
    const name = pending.pop();
    if (visited.has(name)) continue;
    visited.add(name);
    const bodies = definitions.get(name);
    requireCondition(bodies, `${label}: production root/callee ${name} is missing`);
    for (const row of bodies) {
      ranges.push([row.start, row.end]);
      for (const call of row.body.matchAll(/(?<![.\w])(?:[A-Za-z_]\w+\.)?([A-Za-z_]\w*)\s*\(/g)) {
        if (definitions.has(call[1]) && !visited.has(call[1])) pending.push(call[1]);
      }
    }
  }
  return allSites.filter((site) =>
    ranges.some(([start, end]) => site.offset >= start && site.offset < end),
  );
}

function auditAnalyzerFreePath(source, roots, label) {
  const sites = analyzerSitesReachableFrom(source, roots, label);
  requireCondition(
    sites.length === 0,
    `${label}: unexpected analyzer initialization reachable from ${roots.join(', ')}`,
  );
}

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}

function auditTranspile(source, label = 'src/transpile.zig') {
  const code = maskZigNonCode(source);
  const sites = analyzerSitesReachableFrom(source, ['transpile'], label);
  const transpile = functionBody(code, 'transpileWithCallbackInternal', label);
  const body = code.slice(transpile.start, transpile.end);
  requireCondition(
    sites.length === 2,
    `${label}: expected one source analysis and one debug oracle; found ${sites.length} at lines ${sites.map((site) => site.line).join(', ')}`,
  );

  const sourceCall = body.indexOf(
    'analyzer_storage = SemanticAnalyzer.init(arena_alloc, &parser.ast);',
  );
  const sourceGraphGateCalls = [
    ...body.matchAll(
      /\bif\s*\(\s*analyzer_storage\s*\)\s*\|\s*\*a\s*\|\s*try\s+requireStandaloneOutputNormalForm\s*\(/g,
    ),
  ];
  const sourceGraphGate = sourceGraphGateCalls[0]?.index ?? -1;
  const semanticBranches = [
    ...body.matchAll(/\bif\s*\(\s*transform_plan\.semantic\s*==\s*\.full\s*\)\s*\{/g),
  ];
  const semanticOpen = semanticBranches[0]
    ? semanticBranches[0].index + semanticBranches[0][0].lastIndexOf('{')
    : -1;
  const semanticClose = semanticOpen < 0 ? -1 : matchingBrace(body, semanticOpen);
  const sourceAnalyzeCalls = [
    ...body.matchAll(/\banalyzer\.analyze\(\)\s*catch\s*return\s*error\.SemanticError\s*;/g),
  ];
  const sourceAnalyze = sourceAnalyzeCalls[0]?.index ?? -1;
  const diagnosticGuards = coverageDiagnosticGuardRanges(body);
  const sourceGraphSites = [sourceCall, sourceAnalyze, sourceGraphGate];
  const sourceGraphUnderDiagnosticGuard = sourceGraphSites.some(
    (site) => site >= 0 && diagnosticGuards.some(([start, end]) => site >= start && site < end),
  );
  const lateNameSelection = body.indexOf('buildStandaloneLateOutputNameOverrides(');
  const codegen = body.indexOf('Codegen.initWithOptions(');
  const guard =
    'if (symbol_coverage_env.enabled() and (options.minify_syntax or options.minify_identifiers))';
  const guardStart = body.indexOf(guard);
  const guardOpen = guardStart === -1 ? -1 : body.indexOf('{', guardStart + guard.length);
  const guardClose = guardOpen === -1 ? -1 : matchingBrace(body, guardOpen);
  const oracleCall = body.indexOf('SemanticAnalyzer.init(arena_alloc, transformer.ast);');
  const oracleAnalyze = body.indexOf('post_minify_analyzer.analyze()', oracleCall);
  const oracleReport = body.indexOf('checkPostMinifyWithNativeOwners(', oracleCall);
  const oraclePrint = body.indexOf('post_minify_coverage.printPostMinify(', oracleCall);

  requireCondition(
    semanticBranches.length === 1 &&
      semanticClose > semanticOpen &&
      sourceCall > semanticOpen &&
      sourceCall < semanticClose,
    `${label}: source graph construction must stay inside the full-semantic branch`,
  );
  requireCondition(
    sourceAnalyzeCalls.length === 1 &&
      sourceAnalyze > sourceCall &&
      sourceAnalyze < semanticClose &&
      sourceGraphGateCalls.length === 1 &&
      sourceGraphGate > sourceAnalyze,
    `${label}: the parser AST must be fully analyzed before output identity validation`,
  );
  requireCondition(
    !sourceGraphUnderDiagnosticGuard,
    `${label}: source graph construction, analysis, and identity validation must not depend on coverage diagnostics`,
  );
  requireCondition(
    lateNameSelection > sourceGraphGate && codegen > sourceGraphGate,
    `${label}: exact output identity must pass before final-name selection and codegen`,
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
    !/transformer\.symbol_ids\s*=\s*post_minify_analyzer\./.test(body.slice(guardOpen, guardClose)),
    `${label}: diagnostic IDs must not replace producer IDs`,
  );
}

function auditSingleInitialAnalysis(source, file, expectedCall, root) {
  const code = maskZigNonCode(source);
  const sites = analyzerSitesReachableFrom(source, [root], file);
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
  const code = maskZigNonCode(source);
  const productionSites = analyzerSitesReachableFrom(source, ['run'], label);
  const run = functionBody(code, 'run', label);
  const runCandidate = functionBody(code, 'runCandidate', label);
  const normalForm = functionBody(code, 'genericPreparedOutputHasNormalForm', label);
  const completeCandidate = functionBody(code, 'completeGenericPrepassCandidate', label);
  const oracle = functionBody(code, 'refreshSemanticAndStmtInfoAfterAstMutation', label);
  const wrapper = functionBody(code, 'resyncAfterAstMutationForTest', label);
  const allSites = analyzerInitSites(source, true).sites;
  const oracleSites = allSites.filter(
    (site) => site.offset >= oracle.start && site.offset < oracle.end,
  );
  const wrapperCallSites = [
    ...code.matchAll(/\brefreshSemanticAndStmtInfoAfterAstMutation\s*\(/g),
  ].filter((match) => match.index >= wrapper.start && match.index < wrapper.end);
  const allRefreshReferences = [
    ...code.matchAll(/\brefreshSemanticAndStmtInfoAfterAstMutation\s*\(/g),
  ];
  const oracleName = code.indexOf('refreshSemanticAndStmtInfoAfterAstMutation', oracle.declaration);
  const refreshCallSites = allRefreshReferences.filter((match) => match.index !== oracleName);

  requireCondition(
    productionSites.length === 0 && oracleSites.length === 1,
    `${label}: the production prepass call graph must not initialize an analyzer; only its test oracle may do so`,
  );
  const identityGate = normalForm.body.indexOf('report.hasCompleteOutputIdentityBeforeNames()');
  const candidateGate = completeCandidate.body.indexOf('genericPreparedOutputHasNormalForm(');
  const candidateFailure = completeCandidate.body.indexOf('if (!has_normal_form)');
  const failureOpen =
    candidateFailure < 0 ? -1 : completeCandidate.body.indexOf('{', candidateFailure);
  const failureClose = failureOpen < 0 ? -1 : matchingBrace(completeCandidate.body, failureOpen);
  const candidateSuccess = completeCandidate.body.indexOf('candidate_completed.* = true;');
  const candidateSuccessSites = [...code.matchAll(/candidate_completed\.\*\s*=\s*true\s*;/g)];
  const runCandidateCall = run.body.indexOf('runCandidate(');
  const runFailure = run.body.indexOf('if (!candidate_completed)');
  const runFailureOpen = runFailure < 0 ? -1 : run.body.indexOf('{', runFailure);
  const runFailureClose = runFailureOpen < 0 ? -1 : matchingBrace(run.body, runFailureOpen);
  const publish = run.body.indexOf('prepared.publish(');

  requireCondition(
    identityGate >= 0 &&
      /const\s+valid\s*=\s*report\.hasCompleteOutputIdentityBeforeNames\s*\(\s*\)\s*;/.test(
        normalForm.body,
      ) &&
      normalForm.body.indexOf('return valid;') > identityGate &&
      !/\breturn\s+true\s*;/.test(normalForm.body),
    `${label}: generic prepass must return the exact output normal-form result`,
  );
  requireCondition(
    candidateGate >= 0 &&
      /const\s+has_normal_form\s*=\s*genericPreparedOutputHasNormalForm\s*\(/.test(
        completeCandidate.body,
      ) &&
      candidateFailure > candidateGate &&
      failureClose > failureOpen &&
      /\breturn\s*;/.test(completeCandidate.body.slice(failureOpen, failureClose)) &&
      candidateSuccess > failureClose &&
      [...completeCandidate.body.matchAll(/candidate_completed\.\*\s*=\s*true\s*;/g)].length ===
        1 &&
      candidateSuccessSites.length === 1 &&
      candidateSuccessSites[0].index >= completeCandidate.start &&
      candidateSuccessSites[0].index < completeCandidate.end,
    `${label}: a failed exact output gate must abort before candidate completion`,
  );
  requireCondition(
    runCandidate.body.includes('completeGenericPrepassCandidate('),
    `${label}: production candidate preparation must run the exact output gate`,
  );
  requireCondition(
    runCandidateCall >= 0 &&
      runFailure > runCandidateCall &&
      runFailureClose > runFailureOpen &&
      /\breturn\s*;/.test(run.body.slice(runFailureOpen, runFailureClose)) &&
      publish > runFailureClose &&
      !/candidate_completed\s*=\s*true/.test(run.body),
    `${label}: the staged module must publish only after a completed candidate`,
  );
  requireCondition(
    wrapperCallSites.length === 1 &&
      refreshCallSites.length === 1 &&
      refreshCallSites[0].index >= wrapper.start &&
      refreshCallSites[0].index < wrapper.end,
    `${label}: semantic refresh helper must only be called by its test oracle wrapper`,
  );
  requireCondition(
    /if\s*\(\s*!@import\s*\(\s*[^)]*\)\s*\.is_test\s*\)\s*@compileError\s*\(/.test(wrapper.body),
    `${label}: test oracle wrapper must carry its production compile fence`,
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
  const sourceInit = '    analyzer_storage = SemanticAnalyzer.init(arena_alloc, &parser.ast);';
  const sourceAnalyze = '    analyzer.analyze() catch return error.SemanticError;';
  const sourceGraphGate =
    '  if (analyzer_storage) |*a| try requireStandaloneOutputNormalForm(arena_alloc, file_path, &transformer, a, root, pre_transform_scope_count, pre_transform_scope_history_event_count);';
  const transpile =
    `fn transpile() { transpileWithCallbackInternal(); }\n` +
    `fn transpileWithCallbackInternal() {\n` +
    `  if (transform_plan.semantic == .full) {\n` +
    `${sourceInit}\n` +
    `    var analyzer = &analyzer_storage.?;\n` +
    `${sourceAnalyze}\n` +
    `  }\n` +
    `${sourceGraphGate}\n` +
    `  if (symbol_coverage_env.enabled() and (options.minify_syntax or options.minify_identifiers)) {\n` +
    `    var post_minify_analyzer = SemanticAnalyzer.init(arena_alloc, transformer.ast);\n` +
    `    post_minify_analyzer.analyze() catch return error.SemanticError;\n` +
    `    checkPostMinifyWithNativeOwners();\n` +
    `    post_minify_coverage.printPostMinify(file_path, report);\n` +
    `  }\n` +
    `  buildStandaloneLateOutputNameOverrides();\n` +
    `  Codegen.initWithOptions();\n` +
    `}\n` +
    `test "test-only analyzer" { var a = SemanticAnalyzer.init(alloc, ast); }\n`;
  auditTranspile(transpile, 'fixture/transpile.zig');
  auditSingleInitialAnalysis(
    'fn parseModule() { var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast); }',
    'fixture/parse_module.zig',
    'SemanticAnalyzer.init(arena_alloc, &parser.ast)',
    'parseModule',
  );
  const prepass =
    'pub fn run() { var candidate_completed = false; runCandidate(&candidate_completed); if (!candidate_completed) { return; } prepared.publish(self.allocator); }\n' +
    'fn runCandidate(candidate_completed: *bool) { completeGenericPrepassCandidate(candidate_completed); }\n' +
    'fn genericPreparedOutputHasNormalForm() { const valid = report.hasCompleteOutputIdentityBeforeNames(); return valid; }\n' +
    'fn completeGenericPrepassCandidate(candidate_completed: *bool) { const has_normal_form = genericPreparedOutputHasNormalForm(); if (!has_normal_form) { return; } candidate_completed.* = true; }\n' +
    'test "earlier unit test" { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
    'fn refreshSemanticAndStmtInfoAfterAstMutation() { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
    'pub fn resyncAfterAstMutationForTest() { if (!@import("builtin").is_test) @compileError("test only"); refreshSemanticAndStmtInfoAfterAstMutation(); }\n' +
    'test "later unit test" { var a = SemanticAnalyzer.init(alloc, ast); }';
  auditPrepass(prepass);
  auditAnalyzerFreePath(
    'fn productionRoot() { safeHelper(); }\n' +
      'fn safeHelper() {}\n' +
      'fn unreachableUnitHelper() { var a = SemanticAnalyzer.init(alloc, ast); }',
    ['productionRoot'],
    'fixture/reachable-call-graph.zig',
  );

  tryReject(
    () =>
      auditTranspile(
        transpile.replace(
          sourceGraphGate,
          '  var replacement = SemanticAnalyzer.init(arena_alloc, transformer.ast);',
        ),
      ),
    'new production analyzer in transpile',
  );
  tryReject(
    () =>
      auditTranspile(
        transpile.replace(
          sourceGraphGate,
          '  const FreshAnalyzer = SemanticAnalyzer; var replacement = FreshAnalyzer.init(arena_alloc, transformer.ast);',
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
      auditTranspile(
        transpile.replace(
          sourceGraphGate,
          `  buildStandaloneLateOutputNameOverrides();\n${sourceGraphGate}`,
        ),
      ),
    'standalone output gate moved after late-name selection',
  );
  tryReject(
    () =>
      auditTranspile(
        transpile.replace(sourceGraphGate, `  Codegen.initWithOptions();\n${sourceGraphGate}`),
      ),
    'standalone output gate moved after codegen setup',
  );
  for (const [index, env] of ['symbol_coverage_env', 'synthetic_coverage_env'].entries()) {
    tryReject(
      () =>
        auditTranspile(
          transpile.replace(sourceInit, `    if (${env}.enabled()) { ${sourceInit.trim()} }`),
        ),
      `source analyzer initialization gated by ${env} (${index + 1})`,
    );
    tryReject(
      () =>
        auditTranspile(
          transpile.replace(sourceInit, `    if (${env}.enabled()) ${sourceInit.trim()}`),
        ),
      `source analyzer initialization inline-gated by ${env} (${index + 1})`,
    );
    tryReject(
      () =>
        auditTranspile(
          transpile.replace(sourceAnalyze, `    if (${env}.enabled()) { ${sourceAnalyze.trim()} }`),
        ),
      `source analyzer execution gated by ${env} (${index + 1})`,
    );
    tryReject(
      () =>
        auditTranspile(
          transpile.replace(sourceAnalyze, `    if (${env}.enabled()) ${sourceAnalyze.trim()}`),
        ),
      `source analyzer execution inline-gated by ${env} (${index + 1})`,
    );
    tryReject(
      () =>
        auditTranspile(
          transpile.replace(
            sourceAnalyze,
            `    if (${env}.enabled()) {} else ${sourceAnalyze.trim()}`,
          ),
        ),
      `source analyzer execution moved into ${env} else branch (${index + 1})`,
    );
    tryReject(
      () =>
        auditTranspile(
          transpile.replace(
            sourceGraphGate,
            `  if (${env}.enabled()) {\n    ${sourceGraphGate.trim()}\n  }`,
          ),
        ),
      `output identity gate gated by ${env} (${index + 1})`,
    );
    tryReject(
      () =>
        auditTranspile(
          transpile.replace(sourceGraphGate, `  if (${env}.enabled()) ${sourceGraphGate.trim()}`),
        ),
      `output identity gate inline-gated by ${env} (${index + 1})`,
    );
  }
  tryReject(
    () =>
      auditTranspile(
        transpile.replace(
          sourceGraphGate,
          sourceGraphGate.replace(
            'if (analyzer_storage) |*a|',
            'if (analyzer_storage != null and false)',
          ),
        ),
      ),
    'output identity gate hidden behind a false graph-presence check',
  );
  tryReject(
    () =>
      auditTranspile(
        transpile.replace(
          'if (transform_plan.semantic == .full)',
          'if (transform_plan.semantic == .bindings)',
        ),
      ),
    'source identity analysis moved to the bindings-only path',
  );
  tryReject(
    () => auditTranspile(transpile.replace(`${sourceAnalyze}\n`, '')),
    'source analyzer execution removed',
  );
  tryReject(
    () => auditTranspile(transpile.replace(sourceAnalyze, '    analyzer.analyze() catch {};')),
    'source analyzer failure ignored',
  );
  tryReject(
    () =>
      auditTranspile(
        transpile
          .replace(`${sourceGraphGate}\n`, '')
          .replace(sourceAnalyze, `${sourceGraphGate.trim()}\n${sourceAnalyze.trim()}`),
      ),
    'output identity validation moved before source analysis',
  );
  tryReject(
    () => auditTranspile(transpile.replace('&parser.ast', '&transformer.ast')),
    'source analyzer retargeted to the transformed AST',
  );
  tryReject(
    () =>
      auditSingleInitialAnalysis(
        'fn parseModule() { var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast); var replacement = Analyzer.init(a, ast); }',
        'fixture/parse_module.zig',
        'SemanticAnalyzer.init(arena_alloc, &parser.ast)',
        'parseModule',
      ),
    'new parse-module analyzer',
  );
  tryReject(
    () =>
      auditSingleInitialAnalysis(
        'const FreshAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer; fn parseModule() { var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast); var replacement = FreshAnalyzer.init(a, ast); }',
        'fixture/parse_module.zig',
        'SemanticAnalyzer.init(arena_alloc, &parser.ast)',
        'parseModule',
      ),
    'import-aliased parse-module analyzer',
  );
  tryReject(
    () =>
      auditSingleInitialAnalysis(
        'fn parseJsonModule() { var analyzer = SemanticAnalyzer.init(arena_alloc, &(module.ast.?)); var replacement = Analyzer.init(a, ast); }',
        'fixture/json_module.zig',
        'SemanticAnalyzer.init(arena_alloc, &(module.ast.?))',
        'parseJsonModule',
      ),
    'extra JSON-domain analyzer',
  );
  tryReject(
    () =>
      auditPrepass(
        'pub fn run() { runCandidate(); }\n' +
          'fn runCandidate() { var replacement = SemanticAnalyzer.init(alloc, ast); }\n' +
          'fn refreshSemanticAndStmtInfoAfterAstMutation() { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
          'pub fn resyncAfterAstMutationForTest() { if (!@import("builtin").is_test) @compileError("test only"); refreshSemanticAndStmtInfoAfterAstMutation(); }\n' +
          'test "test helper" {}',
      ),
    'new production analyzer in prepass',
  );
  tryReject(
    () =>
      auditPrepass(
        'const FreshAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer; pub fn run() { runCandidate(); } fn runCandidate() { var replacement = FreshAnalyzer.init(alloc, ast); }\n' +
          'fn refreshSemanticAndStmtInfoAfterAstMutation() { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
          'pub fn resyncAfterAstMutationForTest() { if (!@import("builtin").is_test) @compileError("test only"); refreshSemanticAndStmtInfoAfterAstMutation(); }\n' +
          'test "test helper" {}',
      ),
    'aliased production analyzer in prepass',
  );
  tryReject(
    () =>
      auditPrepass(
        prepass.replace(
          'const has_normal_form = genericPreparedOutputHasNormalForm();',
          'const has_normal_form = true;',
        ),
      ),
    'prepass candidate bypassed exact output normal-form call',
  );
  tryReject(
    () => auditPrepass(prepass.replace('if (!has_normal_form)', 'if (has_normal_form)')),
    'prepass candidate failure branch inverted',
  );
  tryReject(
    () =>
      auditPrepass(
        prepass.replace(
          'const has_normal_form = genericPreparedOutputHasNormalForm();',
          'candidate_completed.* = true; const has_normal_form = genericPreparedOutputHasNormalForm();',
        ),
      ),
    'prepass candidate marked complete before exact gate',
  );
  tryReject(
    () =>
      auditPrepass(
        prepass.replace('report.hasCompleteOutputIdentityBeforeNames()', 'report.exact.isClean()'),
      ),
    'prepass normal-form gate reduced to exact counters only',
  );
  tryReject(
    () => auditPrepass(prepass.replace('return valid;', 'return true;')),
    'prepass normal-form result ignored',
  );
  tryReject(
    () => auditPrepass(prepass.replace('if (!candidate_completed) { return; }', '')),
    'prepass transaction published without failed-candidate abort',
  );
  tryReject(
    () =>
      auditPrepass(
        prepass.replace(
          'runCandidate(&candidate_completed);',
          'prepared.publish(self.allocator); runCandidate(&candidate_completed);',
        ),
      ),
    'prepass publication moved before candidate validation',
  );
  tryReject(
    () =>
      auditPrepass(
        prepass.replace(
          'completeGenericPrepassCandidate(candidate_completed); }',
          'candidate_completed.* = true; completeGenericPrepassCandidate(candidate_completed); }',
        ),
      ),
    'prepass marked an ungated candidate complete',
  );
  tryReject(
    () =>
      auditPrepass(prepass.replace('completeGenericPrepassCandidate(candidate_completed); }', '}')),
    'prepass production candidate skipped exact completion gate',
  );
  tryReject(
    () =>
      auditPrepass(
        'pub fn run() { runCandidate(); }\n' +
          'fn runCandidate() {}\n' +
          'fn refreshSemanticAndStmtInfoAfterAstMutation() { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
          'pub fn resyncAfterAstMutationForTest() { refreshSemanticAndStmtInfoAfterAstMutation(); }\n' +
          'test "test helper" {}',
      ),
    'test-only compile fence removed',
  );
  tryReject(
    () =>
      auditPrepass(
        'pub fn run() { runCandidate(); }\n' +
          'fn runCandidate() {}\n' +
          'fn refreshSemanticAndStmtInfoAfterAstMutation() { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
          'test "test helper" {}',
      ),
    'test-only resync wrapper removed',
  );
  tryReject(
    () =>
      auditPrepass(
        'pub fn run() { runCandidate(); }\n' +
          'fn runCandidate() {}\n' +
          'fn refreshSemanticAndStmtInfoAfterAstMutation() { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
          'pub fn resyncAfterAstMutationForTest() { // if (!@import("builtin").is_test) @compileError("test only");\n refreshSemanticAndStmtInfoAfterAstMutation(); }\n' +
          'test "test helper" {}',
      ),
    'commented-out compile fence',
  );
  tryReject(
    () =>
      auditPrepass(
        'pub fn run() { runCandidate(); lateProductionPath(); }\n' +
          'fn runCandidate() {}\n' +
          'test "first test" {}\n' +
          'fn refreshSemanticAndStmtInfoAfterAstMutation() { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
          'pub fn resyncAfterAstMutationForTest() { if (!@import("builtin").is_test) @compileError("test only"); refreshSemanticAndStmtInfoAfterAstMutation(); }\n' +
          'fn lateProductionPath() { var replacement = Analyzer.init(alloc, ast); }\n' +
          'test "last test" {}',
      ),
    'production analyzer added after an earlier test block',
  );
  tryReject(
    () =>
      auditPrepass(
        'pub fn run() { runCandidate(); }\n' +
          'fn runCandidate() { refreshSemanticAndStmtInfoAfterAstMutation(); }\n' +
          'fn refreshSemanticAndStmtInfoAfterAstMutation() { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
          'pub fn resyncAfterAstMutationForTest() { if (!@import("builtin").is_test) @compileError("test only"); refreshSemanticAndStmtInfoAfterAstMutation(); }\n' +
          'test "test helper" {}',
      ),
    'test oracle helper gained a production caller',
  );
  tryReject(
    () =>
      auditPrepass(
        'pub fn run() { runCandidate(); anotherOracle(); }\n' +
          'fn runCandidate() {}\n' +
          'fn refreshSemanticAndStmtInfoAfterAstMutation() { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
          'pub fn resyncAfterAstMutationForTest() { if (!@import("builtin").is_test) @compileError("test only"); refreshSemanticAndStmtInfoAfterAstMutation(); }\n' +
          'fn anotherOracle() { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
          'test "test helper" {}',
      ),
    'additional analyzer helper added outside the test oracle',
  );
  tryReject(
    () =>
      auditAnalyzerFreePath(
        'const FreshAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;\n' +
          'fn productionRoot() { unsafeHelper(); }\n' +
          'fn unsafeHelper() { var a = FreshAnalyzer.init(alloc, ast); }',
        ['productionRoot'],
        'fixture/transitive-call-graph.zig',
      ),
    'aliased analyzer added in a reachable helper',
  );
  tryReject(
    () =>
      auditAnalyzerFreePath(
        'fn productionRoot() { dispatcher.unsafeHelper(); }\n' +
          'fn unsafeHelper() { var a = SemanticAnalyzer.init(alloc, ast); }',
        ['productionRoot'],
        'fixture/qualified-call-graph.zig',
      ),
    'analyzer hidden behind a qualified same-file helper call',
  );
  console.log(
    'semantic reanalysis and output-gate audit self-test PASS (49 hostile mutations rejected)',
  );
}

if (process.argv.includes('--self-test')) {
  try {
    selfTest();
  } catch (error) {
    console.error(`semantic reanalysis and output-gate audit self-test FAIL: ${error.message}`);
    process.exit(1);
  }
  process.exit(0);
}

try {
  selfTest();
  const transpile = readFileSync(join(root, 'src/transpile.zig'), 'utf8');
  const parseModule = readFileSync(join(root, 'src/bundler/graph/parse_module.zig'), 'utf8');
  const jsonModule = readFileSync(join(root, 'src/bundler/graph/json_module.zig'), 'utf8');
  const prepass = readFileSync(join(root, 'src/bundler/graph/transform_prepass.zig'), 'utf8');
  const constMaterialize = readFileSync(
    join(root, 'src/bundler/tree_shaker/const_materialize.zig'),
    'utf8',
  );
  const treeShaker = readFileSync(join(root, 'src/bundler/tree_shaker.zig'), 'utf8');

  auditTranspile(transpile);
  auditSingleInitialAnalysis(
    parseModule,
    'src/bundler/graph/parse_module.zig',
    'SemanticAnalyzer.init(arena_alloc, &parser.ast)',
    'parseModule',
  );
  auditSingleInitialAnalysis(
    jsonModule,
    'src/bundler/graph/json_module.zig',
    'SemanticAnalyzer.init(arena_alloc, &(module.ast.?))',
    'parse',
  );
  auditPrepass(prepass);
  auditAnalyzerFreePath(
    prepass,
    ['materializeFromCachedAst', 'prepareNodeBufferCapabilityFold'],
    'src/bundler/graph/transform_prepass.zig retained graph owners',
  );
  auditAnalyzerFreePath(
    constMaterialize,
    [
      'materializeFullPrepass',
      'propagateNumericExportConstFacts',
      'materializeNumericConstFactsWorklist',
    ],
    'src/bundler/tree_shaker/const_materialize.zig',
  );
  auditAnalyzerFreePath(
    treeShaker,
    ['applyNodeBufferCapabilityFacts'],
    'src/bundler/tree_shaker.zig',
  );
  console.log('semantic reanalysis and output-gate audit PASS');
} catch (error) {
  console.error(`semantic reanalysis and output-gate audit FAIL: ${error.message}`);
  process.exit(1);
}
