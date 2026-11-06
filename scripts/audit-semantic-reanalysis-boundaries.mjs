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

function auditOutputNormalFormAdmissionOptions(source, label) {
  const code = maskZigNonCode(source);
  const checks = [...code.matchAll(/\bcheckOutputNormalFormQuiet\s*\(/g)];
  requireCondition(
    checks.length === 1,
    `${label}: expected exactly one output normal-form admission call; found ${checks.length}`,
  );
  const open = code.indexOf('(', checks[0].index);
  const close = matchingDelimiter(code, open, '(', ')');
  requireCondition(close > open, `${label}: output normal-form call is malformed`);
  const args = code.slice(open + 1, close);
  const options = [...args.matchAll(/\.require_declaration_anchors\s*=\s*(true|false)\b/g)];
  requireCondition(
    options.length === 1 && options[0][1] === 'true',
    `${label}: output normal-form admission must explicitly require declaration anchors`,
  );
  const scopeCount = [...args.matchAll(/\.pre_transform_scope_count\s*=\s*([^,\n}]+)/g)];
  requireCondition(
    scopeCount.length === 1 && scopeCount[0][1].trim() !== 'null',
    `${label}: output normal-form admission must provide one non-null pre-transform scope boundary`,
  );
  const scopeHistoryEpoch = [
    ...args.matchAll(/\.pre_transform_scope_history_event_count\s*=\s*([^,\n}]+)/g),
  ];
  requireCondition(
    scopeHistoryEpoch.length === 1 && scopeHistoryEpoch[0][1].trim() !== 'null',
    `${label}: output normal-form admission must provide one non-null scope-history epoch`,
  );
}

function auditRetainedConstCandidateGate(source, label) {
  const code = maskZigNonCode(source);
  const gate = functionBody(code, 'retainedConstCandidateHasNormalForm', label);
  auditOutputNormalFormAdmissionOptions(gate.body, `${label}: retained const gate`);
  requireCondition(
    /if\s*\(\s*!@import\s*\(\s*[^)]*\)\s*\.outputGraphSidecarsRemainReachable\s*\(/.test(gate.body),
    `${label}: retained const gate must validate graph sidecar reachability`,
  );
  requireCondition(
    /return\s+normal_form\.hasCompleteOutputIdentityBeforeNames\s*\(\s*\)\s*;/.test(gate.body),
    `${label}: retained const gate must return the complete output identity result`,
  );

  const transaction = functionBody(code, 'prepareAndPublishConstFactsForIndex', label);
  const branchStart = transaction.body.indexOf('if (skip_minify) blk: {');
  requireCondition(branchStart >= 0, `${label}: skip-minify publication branch is missing`);
  const branchOpen = transaction.body.indexOf('{', branchStart);
  const branchClose = matchingBrace(transaction.body, branchOpen);
  requireCondition(branchClose > branchOpen, `${label}: skip-minify branch is malformed`);
  const branch = transaction.body.slice(branchOpen + 1, branchClose);
  const call = branch.indexOf('retainedConstCandidateHasNormalForm(');
  const rejection = branch.indexOf('if (!identity_complete) break :blk false;');
  const success = branch.indexOf('break :blk true;');
  requireCondition(
    call >= 0 && rejection > call && success > rejection,
    `${label}: skip-minify candidate must fail closed on incomplete identity before success`,
  );
  requireCondition(
    /catch\s*\|err\|\s*\{\s*if\s*\(err\s*==\s*error\.OutOfMemory\)\s*return\s+err\s*;\s*break\s*:blk\s+false\s*;\s*\}/.test(
      branch,
    ),
    `${label}: non-OOM identity-check errors must abort the candidate`,
  );
  const incomplete = transaction.body.indexOf('if (!complete) return false;');
  const publish = transaction.body.indexOf('prepared.publish();');
  requireCondition(
    incomplete >= 0 && publish > incomplete,
    `${label}: candidate publication must follow the skip-minify rejection barrier`,
  );
}

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}

function auditTranspile(source, label = 'src/transpile.zig') {
  const code = maskZigNonCode(source);
  const sites = analyzerSitesReachableFrom(source, ['transpile'], label);
  const transpile = functionBody(code, 'transpileWithCallbackInternal', label);
  const standaloneNormalForm = functionBody(code, 'standaloneOutputNormalForm', label);
  auditOutputNormalFormAdmissionOptions(standaloneNormalForm.body, `${label}: standalone gate`);
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
  const genericSourceClassOwner = functionBody(code, 'classSelfSidecarHasExactSourceOwner', label);
  const genericSourceClassBinding = functionBody(code, 'classSelfSidecarHasOutputBinding', label);
  const bufferNormalForm = functionBody(code, 'bufferPreparedOutputHasNormalForm', label);
  const bufferFold = functionBody(code, 'prepareNodeBufferCapabilityFold', label);
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
  const genericReachabilityWalk = normalForm.body.indexOf(
    'ast_walk.collectReachableNodeIndicesFrom(allocator, ast, root)',
  );
  const genericSourceReachabilityBranch = normalForm.body.indexOf('if (source_root) |source|');
  const genericSourceReachabilityWalk = normalForm.body.indexOf(
    'ast_walk.collectReachableNodeIndicesFrom(allocator, ast, source)',
  );
  const genericReachableInit = normalForm.body.indexOf(
    'std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len)',
  );
  const genericSourceReachableInit = normalForm.body.indexOf(
    'std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len)',
    genericReachableInit + 1,
  );
  const genericBoundsCheck = normalForm.body.indexOf(
    'if (raw >= ast.nodes.items.len) return false;',
  );
  const genericReachableSet = normalForm.body.search(/(?<!source_)\breachable\.set\(raw\)/);
  const genericSourceBoundsCheck = normalForm.body.indexOf(
    'if (raw >= ast.nodes.items.len) return false;',
    genericBoundsCheck + 1,
  );
  const genericSourceReachableSet = normalForm.body.indexOf('source_reachable.set(raw)');
  const genericSidecarGate = normalForm.body.indexOf(
    'genericPrepassOutputSidecarsRemainReachable(',
  );
  const genericIdentityGate = normalForm.body.indexOf('checkOutputNormalFormQuiet(');
  const genericSidecarAdmissionIsOrdered =
    /if\s*\(\s*!genericPrepassOutputSidecarsRemainReachable\(module,\s*semantic,\s*&reachable,\s*&source_reachable\)\)\s*return\s+false\s*;/.test(
      normalForm.body,
    ) &&
    genericReachabilityWalk >= 0 &&
    genericReachableInit > genericReachabilityWalk &&
    genericBoundsCheck > genericReachableInit &&
    genericReachableSet > genericBoundsCheck &&
    genericSourceReachableInit > genericReachableSet &&
    genericSourceReachabilityBranch > genericSourceReachableInit &&
    genericSourceReachabilityWalk > genericSourceReachabilityBranch &&
    genericSourceBoundsCheck > genericSourceReachabilityWalk &&
    genericSourceReachableSet > genericSourceBoundsCheck &&
    /if\s*\(\s*raw\s*>=\s*ast\.nodes\.items\.len\s*\)\s*return\s+false\s*;/.test(normalForm.body) &&
    genericSidecarGate >= 0 &&
    genericSidecarGate > genericReachableSet &&
    genericSidecarGate > genericSourceReachableSet &&
    genericIdentityGate > genericSidecarGate;
  requireCondition(
    genericSidecarAdmissionIsOrdered,
    `${label}: generic prepass must reject unreachable graph sidecars before output identity admission (${JSON.stringify(
      {
        genericReachabilityWalk,
        genericReachableInit,
        genericBoundsCheck,
        genericReachableSet,
        genericSourceReachabilityWalk,
        genericSourceReachabilityBranch,
        genericSourceReachableInit,
        genericSourceBoundsCheck,
        genericSourceReachableSet,
        genericSidecarGate,
        genericIdentityGate,
        hasFailClosedGate:
          /if\s*\(\s*!genericPrepassOutputSidecarsRemainReachable\(module,\s*semantic,\s*&reachable,\s*&source_reachable\)\)\s*return\s+false\s*;/.test(
            normalForm.body,
          ),
      },
    )})`,
  );
  requireCondition(
    genericSourceClassOwner.body.includes(
      'isNodeReachableInOutputGraph(owner_raw, source_reachable)',
    ) &&
      /owner_raw\s*>=\s*ast\.nodes\.items\.len/.test(genericSourceClassOwner.body) &&
      /symbol_raw\s*>=\s*semantic\.symbols\.items\.len/.test(genericSourceClassOwner.body) &&
      /owner\.tag\s*!=\s*\.class_declaration\s*and\s*owner\.tag\s*!=\s*\.class_expression/.test(
        genericSourceClassOwner.body,
      ) &&
      genericSourceClassOwner.body.includes('source_owner.owner.node') &&
      genericSourceClassOwner.body.includes('source_owner.owner.tag') &&
      genericSourceClassOwner.body.includes('source_owner.edges.body != class_body') &&
      genericSourceClassOwner.body.includes('source_scope.kind != .class_body') &&
      genericSourceClassOwner.body.includes('!source_scope.is_strict') &&
      genericSourceClassOwner.body.includes('symbol.origin_scope != source_owner.scope') &&
      genericSourceClassOwner.body.includes('symbol.kind != .class_decl') &&
      genericSourceClassOwner.body.includes('symbol.scope_id.isNone()') &&
      genericSourceClassOwner.body.includes(
        '@backingInt(symbol.scope_id) >= semantic.scopes.len',
      ) &&
      genericSourceClassOwner.body.includes('symbol.origin_scope.isNone()') &&
      /if\s*\(\s*!name\.isNone\(\)\s+and\s+!std\.mem\.eql\(u8,\s*ast\.getText\(ast\.nodes\.items\[@backingInt\(name\)\]\.span\),\s*symbol\.nameText\(ast\.source\)\)\)\s*return\s+false\s*;/.test(
        genericSourceClassOwner.body,
      ) &&
      genericSourceClassOwner.body.includes('classSelfSidecarHasOutputBinding('),
    `${label}: source-only class-self owners must retain exact source scope and reachable output binding evidence`,
  );
  requireCondition(
    genericSourceClassBinding.body.includes('reachable.isSet(raw)') &&
      genericSourceClassBinding.body.includes('semantic.symbol_ids[raw] != symbol_raw') &&
      genericSourceClassBinding.body.includes('ast.nodes.items[raw].tag != .binding_identifier') &&
      genericSourceClassBinding.body.includes('symbol.nameText(ast.source)') &&
      /if\s*\(\s*reference\.flags\.declare\s+and\s+@backingInt\(reference\.symbol_id\)\s*==\s*symbol_raw/.test(
        genericSourceClassBinding.body,
      ) &&
      genericSourceClassBinding.body.includes('reference.declaration_node_index ==') &&
      /return\s+true\s*;/.test(genericSourceClassBinding.body),
    `${label}: source-only class-self identity must bind to its exact declared output SymbolId`,
  );
  auditOutputNormalFormAdmissionOptions(normalForm.body, `${label}: generic prepass gate`);
  auditOutputNormalFormAdmissionOptions(bufferNormalForm.body, `${label}: Buffer fold gate`);
  const bufferSidecarGate = bufferNormalForm.body.indexOf('outputGraphSidecarsRemainReachable(');
  const bufferIdentityGate = bufferNormalForm.body.indexOf('checkOutputNormalFormQuiet(');
  requireCondition(
    /if\s*\(\s*!outputGraphSidecarsRemainReachable\(module,\s*sem,\s*&reachable\)\)\s*return\s+false\s*;/.test(
      bufferNormalForm.body,
    ) &&
      bufferSidecarGate >= 0 &&
      bufferIdentityGate > bufferSidecarGate,
    `${label}: Buffer fold gate must reject unreachable graph sidecars before output identity admission`,
  );
  const bufferCandidateGate = bufferFold.body.indexOf(
    'if (!try bufferPreparedOutputHasNormalForm(arena_alloc, &prepared.candidate,',
  );
  const bufferCandidateReject = bufferFold.body.indexOf('prepared.discard();', bufferCandidateGate);
  const bufferCandidateAbort = bufferFold.body.indexOf('return null;', bufferCandidateReject);
  const bufferRuntimeRegistration = bufferFold.body.indexOf(
    'prepared.runtime_registration =',
    bufferCandidateGate,
  );
  const bufferCandidateGateArgs = bufferFold.body.slice(bufferCandidateGate, bufferCandidateReject);
  requireCondition(
    bufferCandidateGate >= 0 &&
      /scope_boundary_count/.test(bufferCandidateGateArgs) &&
      /scope_boundary_history_event_count/.test(bufferCandidateGateArgs) &&
      bufferCandidateReject > bufferCandidateGate &&
      bufferCandidateAbort > bufferCandidateReject &&
      bufferRuntimeRegistration > bufferCandidateAbort,
    `${label}: Buffer candidate sidecar and output gate must abort before runtime registration or publication`,
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
  const outputNormalFormOptions =
    '.{ .require_declaration_anchors = true, .pre_transform_scope_count = source_scope_count, .pre_transform_scope_history_event_count = source_history_epoch }';
  const standaloneGateFixture = `fn standaloneOutputNormalForm() { return cov.checkOutputNormalFormQuiet(&origins, ${outputNormalFormOptions}, &source_owned_retirements); }\n`;
  const transpile =
    standaloneGateFixture +
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
  const genericSidecarGuard =
    'if (!genericPrepassOutputSidecarsRemainReachable(module, semantic, &reachable, &source_reachable)) return false;';
  const genericGateFixture = `fn genericPreparedOutputHasNormalForm() { const reachable_nodes = try ast_walk.collectReachableNodeIndicesFrom(allocator, ast, root); var reachable = try std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len); for (reachable_nodes) |raw| { if (raw >= ast.nodes.items.len) return false; reachable.set(raw); } var source_reachable = try std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len); if (source_root) |source| { const source_nodes = try ast_walk.collectReachableNodeIndicesFrom(allocator, ast, source); for (source_nodes) |raw| { if (raw >= ast.nodes.items.len) return false; source_reachable.set(raw); } } ${genericSidecarGuard} const report = report_mod.checkOutputNormalFormQuiet(&origins, ${outputNormalFormOptions}); const valid = report.hasCompleteOutputIdentityBeforeNames(); return valid; }\n`;
  const genericSourceClassOwnerFixture =
    'fn classSelfSidecarHasExactSourceOwner() bool { ' +
    'if (!isNodeReachableInOutputGraph(owner_raw, source_reachable) or owner_raw >= ast.nodes.items.len or symbol_raw >= semantic.symbols.items.len) return false; ' +
    'const owner = ast.nodes.items[owner_raw]; if (owner.tag != .class_declaration and owner.tag != .class_expression) return false; ' +
    'const symbol = semantic.symbols.items[symbol_raw]; if (symbol.kind != .class_decl or symbol.scope_id.isNone() or @backingInt(symbol.scope_id) >= semantic.scopes.len or symbol.origin_scope.isNone()) return false; ' +
    'if (!name.isNone() and !std.mem.eql(u8, ast.getText(ast.nodes.items[@backingInt(name)].span), symbol.nameText(ast.source))) return false; ' +
    'for (semantic.scope_history.source_owners) |source_owner| { ' +
    'if (source_owner.owner.node != owner_raw or source_owner.owner.tag != owner.tag or source_owner.edges.body != class_body) continue; ' +
    'const source_scope = semantic.scope_history.source_scopes[source_owner.scope]; ' +
    'if (source_scope.kind != .class_body or !source_scope.is_strict or symbol.origin_scope != source_owner.scope) return false; ' +
    'return classSelfSidecarHasOutputBinding(ast, semantic, output_reachable, symbol_raw, source_name); } return false; }\n';
  const genericSourceClassBindingFixture =
    'fn classSelfSidecarHasOutputBinding() bool { ' +
    'for (0..reachable.capacity()) |raw| { if (!reachable.isSet(raw) or ast.nodes.items[raw].tag != .binding_identifier or semantic.symbol_ids[raw] != symbol_raw) continue; ' +
    'if (source_name) |name| { if (!std.mem.eql(u8, ast.getText(ast.nodes.items[raw].span), name) or !std.mem.eql(u8, name, symbol.nameText(ast.source))) continue; } ' +
    'for (semantic.references) |reference| { if (reference.flags.declare and @backingInt(reference.symbol_id) == symbol_raw and reference.declaration_node_index == @as(NodeIndex, @intCast(raw))) return true; } } return false; }\n';
  const bufferGateFixture = `fn bufferPreparedOutputHasNormalForm() { if (!outputGraphSidecarsRemainReachable(module, sem, &reachable)) return false; const report = report_mod.checkOutputNormalFormQuiet(&origins, ${outputNormalFormOptions}); return report.hasCompleteOutputIdentityBeforeNames(); }\n`;
  const bufferFoldFixture =
    'fn prepareNodeBufferCapabilityFold() !?PreparedBufferGraph { ' +
    'var prepared = (try prepareBufferGraphForAst()) orelse return null; errdefer prepared.discard(); ' +
    'if (!try bufferPreparedOutputHasNormalForm(arena_alloc, &prepared.candidate, .{ .source = &runtime_source, .module = &prepared.candidate }, scope_boundary_count, scope_boundary_history_event_count)) { prepared.discard(); return null; } ' +
    'prepared.runtime_registration = try prepareRuntimeRegistration(); return prepared; }\n';
  const prepass =
    'pub fn run() { var candidate_completed = false; runCandidate(&candidate_completed); if (!candidate_completed) { return; } prepared.publish(self.allocator); }\n' +
    'fn runCandidate(candidate_completed: *bool) { completeGenericPrepassCandidate(candidate_completed); }\n' +
    genericGateFixture +
    genericSourceClassOwnerFixture +
    genericSourceClassBindingFixture +
    bufferGateFixture +
    bufferFoldFixture +
    'fn completeGenericPrepassCandidate(candidate_completed: *bool) { const has_normal_form = genericPreparedOutputHasNormalForm(); if (!has_normal_form) { return; } candidate_completed.* = true; }\n' +
    'test "earlier unit test" { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
    'fn refreshSemanticAndStmtInfoAfterAstMutation() { var a = SemanticAnalyzer.init(alloc, ast); }\n' +
    'pub fn resyncAfterAstMutationForTest() { if (!@import("builtin").is_test) @compileError("test only"); refreshSemanticAndStmtInfoAfterAstMutation(); }\n' +
    'test "later unit test" { var a = SemanticAnalyzer.init(alloc, ast); }';
  auditPrepass(prepass);
  const constMaterialize = `fn materializeConstFacts() { const report = coverage.checkOutputNormalFormQuiet(&origins, ${outputNormalFormOptions}, &sem.source_owned_retirements); }`;
  auditOutputNormalFormAdmissionOptions(constMaterialize, 'fixture/const_materialize.zig');
  const retainedConstGateFixture =
    `fn retainedConstCandidateHasNormalForm() !bool { ` +
    `if (!@import("../graph/transform_prepass.zig").outputGraphSidecarsRemainReachable(m, sem, &reachable)) return false; ` +
    `const normal_form = try coverage.checkOutputNormalFormQuiet(&origins, ${outputNormalFormOptions}, &sem.source_owned_retirements); ` +
    `return normal_form.hasCompleteOutputIdentityBeforeNames(); }\n`;
  const retainedConstTransactionFixture =
    `fn prepareAndPublishConstFactsForIndex() !bool { ` +
    `const complete = if (skip_minify) blk: { ` +
    `const identity_complete = retainedConstCandidateHasNormalForm() catch |err| { ` +
    `if (err == error.OutOfMemory) return err; break :blk false; }; ` +
    `if (!identity_complete) break :blk false; break :blk true; ` +
    `} else true; if (!complete) return false; prepared.publish(); }\n`;
  const retainedConst = retainedConstGateFixture + retainedConstTransactionFixture;
  auditRetainedConstCandidateGate(retainedConst, 'fixture/const_materialize.zig');
  const mutateScopeBoundary = (source, field, mutation) => {
    const value =
      field === 'pre_transform_scope_count' ? 'source_scope_count' : 'source_history_epoch';
    const assignment = `.${field} = ${value}`;
    if (mutation === 'null') return source.replace(assignment, `.${field} = null`);
    return source.replace(`, ${assignment}`, '');
  };
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
  tryReject(
    () =>
      auditTranspile(
        transpile.replace(
          '.require_declaration_anchors = true',
          '.require_declaration_anchors = false',
        ),
      ),
    'standalone output gate stopped requiring declaration anchors',
  );
  tryReject(
    () => auditTranspile(transpile.replace('.require_declaration_anchors = true', '')),
    'standalone output gate stopped explicitly pinning declaration anchors',
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
    () =>
      auditPrepass(
        prepass.replace(
          '.require_declaration_anchors = true',
          '.require_declaration_anchors = false',
        ),
      ),
    'generic prepass admission stopped requiring declaration anchors',
  );
  tryReject(
    () =>
      auditPrepass(
        prepass.replace(
          bufferGateFixture,
          bufferGateFixture.replace(
            '.require_declaration_anchors = true',
            '.require_declaration_anchors = false',
          ),
        ),
      ),
    'Buffer fold admission stopped requiring declaration anchors',
  );
  tryReject(
    () => auditPrepass(prepass.replace('.require_declaration_anchors = true', '')),
    'generic prepass admission stopped explicitly pinning declaration anchors',
  );
  const genericSidecarMutants = [
    [genericGateFixture.replace(`${genericSidecarGuard} `, ''), 'removed the sidecar rejection'],
    [
      genericGateFixture.replace(
        genericSidecarGuard,
        'if (genericPrepassOutputSidecarsRemainReachable(module, semantic, &reachable, &source_reachable)) return false;',
      ),
      'inverted the sidecar rejection',
    ],
    [
      genericGateFixture.replace(
        genericSidecarGuard,
        'if (!genericPrepassOutputSidecarsRemainReachable(module, semantic, &reachable, &source_reachable)) return true;',
      ),
      'accepted the candidate on a rejected sidecar',
    ],
    [
      genericGateFixture.replace(
        genericSidecarGuard,
        '_ = genericPrepassOutputSidecarsRemainReachable(module, semantic, &reachable, &source_reachable);',
      ),
      'ignored the sidecar result',
    ],
    [
      genericGateFixture.replace(
        genericSidecarGuard,
        'if (!genericPrepassOutputSidecarsRemainReachable(source_module, semantic, &reachable, &source_reachable)) return false;',
      ),
      'validated a different module than the candidate',
    ],
    [
      genericGateFixture.replace(
        genericSidecarGuard,
        'if (!genericPrepassOutputSidecarsRemainReachable(module, source_semantic, &reachable, &source_reachable)) return false;',
      ),
      'validated a different semantic graph than the candidate',
    ],
    [
      genericGateFixture.replace(
        genericSidecarGuard,
        'if (!genericPrepassOutputSidecarsRemainReachable(module, semantic, &empty_reachable, &source_reachable)) return false;',
      ),
      'validated an unrelated reachability bitmap',
    ],
    [
      genericGateFixture.replace(
        genericSidecarGuard,
        'if (!genericPrepassOutputSidecarsRemainReachable(module, semantic, &reachable, &empty_source_reachable)) return false;',
      ),
      'validated an unrelated source-owner bitmap',
    ],
    [
      genericGateFixture
        .replace(`${genericSidecarGuard} `, '')
        .replace('return valid;', `${genericSidecarGuard} return valid;`),
      'checked sidecars only after output identity admission',
    ],
    [
      genericGateFixture.replace(
        genericSidecarGuard,
        'if (module.wrap_kind == .esm and !genericPrepassOutputSidecarsRemainReachable(module, semantic, &reachable, &source_reachable)) return false;',
      ),
      'skipped sidecar validation for CJS candidates',
    ],
    [
      genericGateFixture.replace(
        genericSidecarGuard,
        'if (!genericPrepassOutputSidecarsRemainReachable(module, semantic, &reachable, &source_reachable)) {}',
      ),
      'continued after sidecar rejection',
    ],
  ];
  for (const [mutant, label] of genericSidecarMutants) {
    tryReject(
      () => auditPrepass(prepass.replace(genericGateFixture, mutant)),
      `generic prepass admission ${label}`,
    );
  }
  const genericSourceOwnerMutants = [
    [
      genericSourceClassOwnerFixture.replace(
        'isNodeReachableInOutputGraph(owner_raw, source_reachable)',
        'true',
      ),
      'accepted a source owner absent from the source AST root',
    ],
    [
      genericSourceClassOwnerFixture.replace(
        'owner.tag != .class_declaration and owner.tag != .class_expression',
        'false',
      ),
      'accepted a non-class source owner',
    ],
    [
      genericSourceClassOwnerFixture.replace('source_owner.owner.node != owner_raw', 'false'),
      'accepted a class sidecar owned by a different source node',
    ],
    [
      genericSourceClassOwnerFixture.replace(
        'symbol.origin_scope != source_owner.scope',
        'symbol.origin_scope.isNone()',
      ),
      'dropped exact source class-self scope lineage',
    ],
    [
      genericSourceClassOwnerFixture.replace('symbol.kind != .class_decl', 'false'),
      'accepted a non-class-self SymbolId',
    ],
    [
      genericSourceClassOwnerFixture.replace(
        'symbol.nameText(ast.source))) return false;',
        'symbol.nameText(ast.source))) {}',
      ),
      'dropped the source class name to SymbolId comparison',
    ],
    [
      genericSourceClassOwnerFixture.replace(
        'return classSelfSidecarHasOutputBinding(ast, semantic, output_reachable, symbol_raw, source_name);',
        'return true;',
      ),
      'accepted a source class without an output self binding',
    ],
  ];
  for (const [mutant, label] of genericSourceOwnerMutants) {
    tryReject(
      () => auditPrepass(prepass.replace(genericSourceClassOwnerFixture, mutant)),
      `generic prepass source class-self admission ${label}`,
    );
  }
  const genericSourceBindingMutants = [
    [
      genericSourceClassBindingFixture.replace(
        'reference.flags.declare',
        '!reference.flags.declare',
      ),
      'accepted a non-declaration output binding reference',
    ],
    [
      genericSourceClassBindingFixture.replace(
        'reference.declaration_node_index == @as(NodeIndex, @intCast(raw))',
        'reference.declaration_node_index != @as(NodeIndex, @intCast(raw))',
      ),
      'accepted a different declaration node for the source class-self SymbolId',
    ],
  ];
  for (const [mutant, label] of genericSourceBindingMutants) {
    tryReject(
      () => auditPrepass(prepass.replace(genericSourceClassBindingFixture, mutant)),
      `generic prepass source class-self output binding ${label}`,
    );
  }
  const genericReachabilityMutants = [
    [
      genericGateFixture.replace(
        'const reachable_nodes = try ast_walk.collectReachableNodeIndicesFrom(allocator, ast, root);',
        '',
      ),
      'removed the candidate-root reachability walk',
    ],
    [
      genericGateFixture.replace(
        'std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len)',
        'std.DynamicBitSet.initEmpty(allocator, 0)',
      ),
      'sized the reachability bitmap for no AST nodes',
    ],
    [
      genericGateFixture.replace(
        'if (raw >= ast.nodes.items.len) return false;',
        'if (raw >= ast.nodes.items.len) {}',
      ),
      'continued after an out-of-range reachable node',
    ],
    [
      genericGateFixture.replace('reachable.set(raw);', 'reachable.set(0);'),
      'marked a different node reachable',
    ],
    [
      genericGateFixture.replace(
        'const source_nodes = try ast_walk.collectReachableNodeIndicesFrom(allocator, ast, source);',
        '',
      ),
      'removed the source-root class-owner reachability walk',
    ],
    [
      genericGateFixture.replace(
        'var source_reachable = try std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len);',
        'std.DynamicBitSet.initEmpty(allocator, 0); for (source_nodes)',
      ),
      'sized the source-owner bitmap for no AST nodes',
    ],
    [
      genericGateFixture.replace(
        'if (raw >= ast.nodes.items.len) return false; source_reachable.set(raw);',
        'if (raw >= ast.nodes.items.len) {} source_reachable.set(raw);',
      ),
      'continued after an out-of-range source node',
    ],
    [
      genericGateFixture.replace('source_reachable.set(raw);', 'source_reachable.set(0);'),
      'marked a different source node reachable',
    ],
    [
      genericGateFixture.replace(
        'ast_walk.collectReachableNodeIndicesFrom(allocator, ast, source)',
        'ast_walk.collectReachableNodeIndicesFrom(allocator, ast, root)',
      ),
      'used the candidate root as source-owner evidence',
    ],
  ];
  for (const [mutant, label] of genericReachabilityMutants) {
    tryReject(
      () => auditPrepass(prepass.replace(genericGateFixture, mutant)),
      `generic prepass reachability ${label}`,
    );
  }
  tryReject(
    () =>
      auditPrepass(
        prepass.replace(
          bufferGateFixture,
          bufferGateFixture.replace('.require_declaration_anchors = true', ''),
        ),
      ),
    'Buffer fold admission stopped explicitly pinning declaration anchors',
  );
  const bufferSidecarGuard =
    'if (!outputGraphSidecarsRemainReachable(module, sem, &reachable)) return false;';
  const bufferSidecarMutants = [
    [bufferGateFixture.replace(`${bufferSidecarGuard} `, ''), 'removed the sidecar rejection'],
    [
      bufferGateFixture.replace(
        bufferSidecarGuard,
        'if (outputGraphSidecarsRemainReachable(module, sem, &reachable)) return false;',
      ),
      'inverted the sidecar rejection',
    ],
    [
      bufferGateFixture.replace(
        bufferSidecarGuard,
        'if (!outputGraphSidecarsRemainReachable(module, sem, &reachable)) return true;',
      ),
      'accepted the candidate on a rejected sidecar',
    ],
    [
      bufferGateFixture.replace(
        bufferSidecarGuard,
        '_ = outputGraphSidecarsRemainReachable(module, sem, &reachable);',
      ),
      'ignored the sidecar result',
    ],
    [
      bufferGateFixture.replace(
        bufferSidecarGuard,
        'if (!outputGraphSidecarsRemainReachable(source_module, sem, &reachable)) return false;',
      ),
      'validated a different module than the candidate',
    ],
    [
      bufferGateFixture.replace(
        bufferSidecarGuard,
        'if (!outputGraphSidecarsRemainReachable(module, source_semantic, &reachable)) return false;',
      ),
      'validated a different semantic graph than the candidate',
    ],
    [
      bufferGateFixture.replace(
        bufferSidecarGuard,
        'if (!outputGraphSidecarsRemainReachable(module, sem, &empty_reachable)) return false;',
      ),
      'validated an unrelated reachability bitmap',
    ],
    [
      bufferGateFixture
        .replace(`${bufferSidecarGuard} `, '')
        .replace(
          'return report.hasCompleteOutputIdentityBeforeNames();',
          `${bufferSidecarGuard} return report.hasCompleteOutputIdentityBeforeNames();`,
        ),
      'checked sidecars only after output identity admission',
    ],
    [
      bufferGateFixture.replace(
        bufferSidecarGuard,
        'if (module.wrap_kind == .esm and !outputGraphSidecarsRemainReachable(module, sem, &reachable)) return false;',
      ),
      'skipped sidecar validation for CJS candidates',
    ],
    [
      bufferGateFixture.replace(
        bufferSidecarGuard,
        'if (!outputGraphSidecarsRemainReachable(module, sem, &reachable)) {}',
      ),
      'continued after sidecar rejection',
    ],
  ];
  for (const [mutant, label] of bufferSidecarMutants) {
    tryReject(
      () => auditPrepass(prepass.replace(bufferGateFixture, mutant)),
      `Buffer fold admission ${label}`,
    );
  }
  const bufferCandidateGuard =
    'if (!try bufferPreparedOutputHasNormalForm(arena_alloc, &prepared.candidate, .{ .source = &runtime_source, .module = &prepared.candidate }, scope_boundary_count, scope_boundary_history_event_count)) { prepared.discard(); return null; }';
  const bufferCandidateMutants = [
    [bufferFoldFixture.replace(`${bufferCandidateGuard} `, ''), 'removed candidate admission'],
    [
      bufferFoldFixture.replace(
        bufferCandidateGuard,
        bufferCandidateGuard.replace('if (!try', 'if (try'),
      ),
      'inverted candidate admission',
    ],
    [
      bufferFoldFixture.replace(
        bufferCandidateGuard,
        bufferCandidateGuard.replace('return null;', 'return prepared;'),
      ),
      'returned the candidate after sidecar rejection',
    ],
    [
      bufferFoldFixture.replace(
        bufferCandidateGuard,
        bufferCandidateGuard.replace('prepared.discard(); ', ''),
      ),
      'skipped explicit candidate discard on rejection',
    ],
    [
      bufferFoldFixture.replace(
        bufferCandidateGuard,
        bufferCandidateGuard.replace('return null;', ''),
      ),
      'continued after candidate rejection',
    ],
    [
      bufferFoldFixture.replace(
        bufferCandidateGuard,
        bufferCandidateGuard.replace(
          'bufferPreparedOutputHasNormalForm(arena_alloc, &prepared.candidate,',
          'bufferPreparedOutputHasNormalForm(arena_alloc, module,',
        ),
      ),
      'validated the source module instead of the candidate',
    ],
    [
      bufferFoldFixture
        .replace(`${bufferCandidateGuard} `, '')
        .replace(
          'prepared.runtime_registration = try prepareRuntimeRegistration();',
          `prepared.runtime_registration = try prepareRuntimeRegistration(); ${bufferCandidateGuard}`,
        ),
      'registered runtime metadata before candidate admission',
    ],
    [
      bufferFoldFixture.replace(
        bufferCandidateGuard,
        bufferCandidateGuard.replace('if (!try', 'if (external_reads.count() != 0 and !try'),
      ),
      'skipped candidate admission when no external reads were erased',
    ],
    [
      bufferFoldFixture.replace(
        bufferCandidateGuard,
        bufferCandidateGuard.replace('if (!try', 'if (false and !try'),
      ),
      'disabled candidate admission behind a false condition',
    ],
    [
      bufferFoldFixture.replace(
        bufferCandidateGuard,
        bufferCandidateGuard.replace(
          'scope_boundary_count, scope_boundary_history_event_count',
          'null, null',
        ),
      ),
      'dropped both retained source scope boundaries',
    ],
  ];
  for (const [mutant, label] of bufferCandidateMutants) {
    tryReject(
      () => auditPrepass(prepass.replace(bufferFoldFixture, mutant)),
      `Buffer candidate transaction ${label}`,
    );
  }
  tryReject(
    () =>
      auditOutputNormalFormAdmissionOptions(
        constMaterialize.replace(
          '.require_declaration_anchors = true',
          '.require_declaration_anchors = false',
        ),
        'fixture/const_materialize.zig',
      ),
    'const materialization stopped requiring declaration anchors',
  );
  tryReject(
    () =>
      auditOutputNormalFormAdmissionOptions(
        constMaterialize.replace('.require_declaration_anchors = true', ''),
        'fixture/const_materialize.zig',
      ),
    'const materialization stopped explicitly pinning declaration anchors',
  );
  const retainedMutants = [
    [
      retainedConst.replace(
        'if (!@import("../graph/transform_prepass.zig").outputGraphSidecarsRemainReachable(m, sem, &reachable)) return false;',
        'if (true) {}',
      ),
      'retained const gate accepted an orphan graph sidecar',
    ],
    [
      retainedConst.replace(
        '.require_declaration_anchors = true',
        '.require_declaration_anchors = false',
      ),
      'retained const gate stopped requiring declaration anchors',
    ],
    [
      retainedConst.replace('.require_declaration_anchors = true', ''),
      'retained const gate stopped explicitly pinning declaration anchors',
    ],
    [
      retainedConst.replace(
        '.pre_transform_scope_count = source_scope_count',
        '.pre_transform_scope_count = null',
      ),
      'retained const gate accepted a missing source scope boundary',
    ],
    [
      retainedConst.replace(', .pre_transform_scope_count = source_scope_count', ''),
      'retained const gate accepted an omitted source scope boundary',
    ],
    [
      retainedConst.replace(
        '.pre_transform_scope_history_event_count = source_history_epoch',
        '.pre_transform_scope_history_event_count = null',
      ),
      'retained const gate accepted a missing source scope history epoch',
    ],
    [
      retainedConst.replace(
        ', .pre_transform_scope_history_event_count = source_history_epoch',
        '',
      ),
      'retained const gate accepted an omitted source scope history epoch',
    ],
    [
      retainedConst.replace(
        'return normal_form.hasCompleteOutputIdentityBeforeNames();',
        'return normal_form.exact.isClean();',
      ),
      'retained const gate accepted exact-only output validation',
    ],
    [
      retainedConst.replace(
        'retainedConstCandidateHasNormalForm() catch |err| { if (err == error.OutOfMemory) return err; break :blk false; }',
        'true',
      ),
      'retained const caller bypassed output validation',
    ],
    [
      retainedConst.replace(
        'if (!identity_complete) break :blk false;',
        'if (identity_complete) break :blk false;',
      ),
      'retained const caller inverted its failed-candidate branch',
    ],
    [
      retainedConst.replace(
        'if (!identity_complete) break :blk false;',
        'if (!identity_complete) {}',
      ),
      'retained const caller ignored incomplete output identity',
    ],
    [
      retainedConst.replace(
        'if (!complete) return false; prepared.publish();',
        'prepared.publish(); if (!complete) return false;',
      ),
      'retained const publication moved before the abort barrier',
    ],
  ];
  for (const [mutant, label] of retainedMutants) {
    tryReject(
      () => auditRetainedConstCandidateGate(mutant, 'fixture/const_materialize.zig'),
      label,
    );
  }
  for (const field of ['pre_transform_scope_count', 'pre_transform_scope_history_event_count']) {
    for (const mutation of ['null', 'remove']) {
      tryReject(
        () => auditTranspile(mutateScopeBoundary(transpile, field, mutation)),
        `standalone gate accepted ${mutation} ${field}`,
      );
      tryReject(
        () => auditPrepass(mutateScopeBoundary(prepass, field, mutation)),
        `generic prepass gate accepted ${mutation} ${field}`,
      );
      tryReject(
        () =>
          auditPrepass(
            prepass.replace(
              bufferGateFixture,
              mutateScopeBoundary(bufferGateFixture, field, mutation),
            ),
          ),
        `Buffer fold gate accepted ${mutation} ${field}`,
      );
      tryReject(
        () =>
          auditOutputNormalFormAdmissionOptions(
            mutateScopeBoundary(constMaterialize, field, mutation),
            'fixture/const_materialize.zig',
          ),
        `const materialization gate accepted ${mutation} ${field}`,
      );
    }
  }
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
    'semantic reanalysis and output-gate audit self-test PASS (134 hostile mutations rejected)',
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
  const constMaterializeCode = maskZigNonCode(constMaterialize);
  auditOutputNormalFormAdmissionOptions(
    functionBody(
      constMaterializeCode,
      'prepareJournalConstMinification',
      'src/bundler/tree_shaker/const_materialize.zig',
    ).body,
    'src/bundler/tree_shaker/const_materialize.zig: minifying const gate',
  );
  auditRetainedConstCandidateGate(
    constMaterialize,
    'src/bundler/tree_shaker/const_materialize.zig',
  );
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
