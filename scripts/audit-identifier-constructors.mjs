#!/usr/bin/env node
// 트랜스포머 식별자 생성 audit (#4760 3단계).
//
// 배경: 트랜스포머가 사용자 변수를 가리키는 식별자를 새로 만들면서 "어느 변수인지"(심볼)를 빠뜨리면
// 그 노드만 옛 이름으로 나가거나 minify 가 다른 변수와 묶는다(#4703·#4712·#4762·#4763). 지점별로
// 고치면 새 변환이 들어올 때마다 같은 누락이 생긴다. 그래서 식별자는 **무엇을 가리키는지 고르는**
// 생성 함수로만 만든다:
//   - 사용자 변수: makeIdentifierRefWithSymbol(At) · makeUserRefNamed · makeCurrentClassRef ·
//                  makeRootScopeRef · makeUserBinding  (심볼 전달)
//   - 합성 이름:   makeSyntheticRef(FromSpan/At) · makeSyntheticBinding · makeExactSyntheticBinding(FromSpan) ·
//                  makeTempVarRef · makeRuntimeHelperRef
//   - 전역:        makeGlobalRef(FromSpan/At)
//   - 속성 이름:   makePropertyName(FromSpan/At)
//   - 대입 target: producer가 확정한 SymbolId를 직접 등록하는 허용 함수만
//
//   - JSX:         makeSyntheticJsxTag · makeJsxAttributeName  (사용자 컴포넌트 태그는 원본 노드를 옮긴다)
//
// 규칙: src/transformer 안에서 identifier_reference / assignment_target_identifier /
// binding_identifier / jsx_identifier 노드를 직접 만드는 곳(`.tag = if (…) … else
// .identifier_reference` 같은 조건식 포함)과 `makeBindingIdentifier(` 호출은 아래 ALLOWLIST 의 함수
// 안에서만 허용한다. 등록 안 된 곳이 있으면 CI 실패.
//
// 대상 밖(의도): `private_identifier`(`#x`) 는 스코프 심볼이 아니다. AST 플러그인(`ast_plugin.zig`)은
// 외부 API 라 임의 노드를 만든다 — 플러그인이 만든 식별자의 이름은 변환 뒤 재분석(minify·번들)이 정한다.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve, relative } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(import.meta.dirname, '..');
const scanRoot = join(root, 'src', 'transformer');

// "<relpath>::<fn>" → 사유. 분류된 생성 함수 자신과, Transformer 없이 raw AST 를 만드는 문맥만.
const ALLOWLIST = {
  'src/transformer/es_helpers.zig::identifierRefNode': '분류된 참조 생성 함수들의 공통 노드 생성',
  'src/transformer/es_helpers.zig::makeIdentifierRef':
    'makeSyntheticRef/GlobalRef/PropertyName 의 내부 구현(비공개)',
  'src/transformer/es_helpers.zig::makeIdentifierRefFromSpan':
    '…FromSpan 판·makeIdentifierRefWithSymbol 의 내부 구현',
  'src/transformer/es_helpers.zig::makeTempVarRef': '합성 임시 변수 참조 생성 함수',
  'src/transformer/es_helpers.zig::makeBindingIdentifier':
    'makeSyntheticBinding·makeUserBinding 의 내부 구현',
  'src/transformer/es_helpers.zig::makeSyntheticBinding': '합성 바인딩 생성 함수',
  'src/transformer/es_helpers.zig::makeExactSyntheticBinding':
    '고유 이름을 확정한 합성 바인딩 생성 함수',
  'src/transformer/es_helpers.zig::makeExactSyntheticBindingFromSpan':
    '이미 확정된 이름 Span을 재해석하지 않는 합성 바인딩 생성 함수',
  'src/transformer/es_helpers.zig::makeExactUserWriteTargetAtScope':
    'producer가 고른 사용자 SymbolId와 출력 ScopeId를 생성 시점에 등록하는 write target 생성자',
  'src/transformer/es_helpers.zig::retagAssignmentTargetAsReference':
    '기존 assignment target 노드를 읽기 reference로 재사용',
  'src/transformer/es_helpers.zig::buildCapturedFunctionAssignment':
    '합성 함수 대입 target에 producer가 선택한 SymbolId를 pending 등록',
  'src/transformer/es2015_generator.zig::appendCollectedFunctionAlias':
    'Annex B producer가 선택한 variable SymbolId와 operation ScopeId를 대입 Reference에 직접 등록',
  'src/transformer/static_class_capture.zig::makeClassSelfReference':
    'source class-self SymbolId를 output capture SymbolId에 매핑하고 write Reference를 target으로 재사용',
  'src/transformer/transformer/stage3_decorator_transform.zig::attachClassNameWrite':
    'producer가 확정한 class-self SymbolId와 output ScopeId를 copied write Reference에 직접 등록',
  'src/transformer/transformer/driver.zig::appendParameterBodyVarCopies':
    '이동한 body-var 대입 target을 해당 body SymbolId에 직접 연결',
  'src/transformer/transformer/node_helpers.zig::makeUserBinding':
    '사용자 바인딩 생성 함수(심볼 전달)',
  'src/transformer/es_helpers.zig::jsxIdentifierNode':
    'makeSyntheticJsxTag·makeJsxAttributeName 의 공통 노드 생성',
};

// These existing transformer producers register each assignment target with an
// exact SymbolId/ScopeId. Pin their current raw-constructor count so that adding
// another direct identifier construction inside an allowed producer cannot
// silently widen the exception.
const PINNED_ALLOW_COUNTS = new Map([
  ['src/transformer/es2015_generator.zig::appendCollectedFunctionAlias', 1],
  ['src/transformer/static_class_capture.zig::makeClassSelfReference', 1],
  ['src/transformer/transformer/stage3_decorator_transform.zig::attachClassNameWrite', 1],
  ['src/transformer/es_helpers.zig::makeExactUserWriteTargetAtScope', 1],
]);

const IDENTIFIER_TAGS = [
  'identifier_reference',
  'assignment_target_identifier',
  'binding_identifier',
  'jsx_identifier',
];

function walk(dir, out) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (name.endsWith('.zig') && !name.endsWith('_test.zig')) out.push(p);
  }
  return out;
}

// 뒤로 스캔해 brace scope 안에 있는 가장 가까운 `fn name(` 선언을 찾는다.
// 닫힌 함수를 지난 top-level 변수에 이전 함수의 ALLOWLIST 를 빌려주면 안 된다.
function enclosingFn(lines, i) {
  let enclosingDepth = 0;
  for (let j = i; j >= 0; j--) {
    const m = lines[j].match(/\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/);
    const functionBodyOnLine = m !== null && lines[j].indexOf('{', m.index + m[0].length) !== -1;
    if (m && (enclosingDepth < 0 || j === i || (enclosingDepth === 0 && functionBodyOnLine)))
      return m[1];
    for (let k = lines[j].length - 1; k >= 0; k--) {
      if (lines[j][k] === '}') enclosingDepth++;
      else if (lines[j][k] === '{') enclosingDepth--;
    }
  }
  return '<top>';
}

// Keep inline `test` fixtures out of the production-constructor audit. Zig
// tests can live in a production module, where their AST fixture literals are
// not constructor paths used by the transformer.
function stripZigCommentsAndStrings(line, state) {
  if (/^\s*\\\\/.test(line)) return '';
  let code = '';
  for (let i = 0; i < line.length; i++) {
    if (state.inBlockComment) {
      if (line[i] === '*' && line[i + 1] === '/') {
        state.inBlockComment = false;
        i++;
      }
      continue;
    }
    if (line[i] === '/' && line[i + 1] === '/') break;
    if (line[i] === '/' && line[i + 1] === '*') {
      state.inBlockComment = true;
      i++;
      continue;
    }
    if (line[i] === '"' || line[i] === "'") {
      const quote = line[i];
      i++;
      while (i < line.length) {
        if (line[i] === '\\') i++;
        else if (line[i] === quote) break;
        i++;
      }
      code += ' ';
      continue;
    }
    code += line[i];
  }
  return code;
}

function lineAtOffset(lineStarts, offset) {
  let low = 0;
  let high = lineStarts.length;
  while (low + 1 < high) {
    const mid = (low + high) >>> 1;
    if (lineStarts[mid] <= offset) low = mid;
    else high = mid;
  }
  return low;
}

function tagExpressionEnd(source, start) {
  let parens = 0;
  let brackets = 0;
  let braces = 0;
  for (let i = start; i < source.length; i++) {
    switch (source[i]) {
      case '(':
        parens++;
        break;
      case ')':
        if (parens === 0) return i;
        parens--;
        break;
      case '[':
        brackets++;
        break;
      case ']':
        if (brackets === 0) return i;
        brackets--;
        break;
      case '{':
        braces++;
        break;
      case '}':
        if (braces === 0) return i;
        braces--;
        break;
      case ',':
      case ';':
        if (parens === 0 && brackets === 0 && braces === 0) return i;
        break;
    }
  }
  return source.length;
}

function identifierTagAliases(segmentSource, segment, lineStarts) {
  const aliases = new Map();
  const bindings = new Map();
  const declarations = /\b(?:const|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b[^=;\n]*=/g;
  const identifierTag = new RegExp(`\\.(${IDENTIFIER_TAGS.join('|')})\\b`);
  for (const declaration of segmentSource.matchAll(declarations)) {
    const name = declaration[1];
    const initializerStart = declaration.index + declaration[0].length;
    const initializerEnd = tagExpressionEnd(segmentSource, initializerStart);
    const initializer = segmentSource.slice(initializerStart, initializerEnd).trim();
    const line = lineAtOffset(lineStarts, declaration.index);
    const fn = enclosingFn(segment.lines, line);
    const key = `${fn}::${name}`;
    const bindingRows = bindings.get(key) ?? [];
    bindingRows.push({ offset: declaration.index });
    bindings.set(key, bindingRows);
    const directTag = initializer.match(identifierTag)?.[1];
    const sourceAlias = initializer.match(/^([A-Za-z_][A-Za-z0-9_]*)$/)?.[1];
    const sourceKey = sourceAlias === undefined ? undefined : `${fn}::${sourceAlias}`;
    const sourceBinding =
      sourceKey === undefined
        ? undefined
        : (bindings.get(sourceKey)?.findLast((binding) => binding.offset < declaration.index) ??
          bindings.get(`<top>::${sourceAlias}`)?.at(-1));
    const aliasTag =
      directTag ??
      (sourceKey === undefined || sourceBinding === undefined
        ? undefined
        : (aliases.get(sourceKey)?.findLast((alias) => alias.offset === sourceBinding.offset)
            ?.tag ??
          aliases
            .get(`<top>::${sourceAlias}`)
            ?.findLast((alias) => alias.offset === sourceBinding.offset)?.tag));
    if (aliasTag === undefined) continue;
    const entries = aliases.get(key) ?? [];
    entries.push({ tag: aliasTag, offset: declaration.index });
    aliases.set(key, entries);
  }
  return { aliases, bindings };
}

function sourceSegments(source) {
  const lines = source.split('\n');
  const lexical = { inBlockComment: false };
  let braceDepth = 0;
  let testBlockDepth = null;
  const segments = [];
  let currentLines = [];
  let currentStartLine = 0;
  const flush = () => {
    if (currentLines.length === 0) return;
    segments.push({ startLine: currentStartLine, lines: currentLines });
    currentLines = [];
  };

  lines.forEach((line, i) => {
    const code = stripZigCommentsAndStrings(line, lexical);
    const startsTest = testBlockDepth === null && braceDepth === 0 && /^\s*test\b/.test(code);
    const insideTest = testBlockDepth !== null || startsTest;
    if (insideTest) {
      flush();
    } else {
      if (currentLines.length === 0) currentStartLine = i;
      currentLines.push(code);
    }

    const opens = (code.match(/{/g) ?? []).length;
    const closes = (code.match(/}/g) ?? []).length;
    if (startsTest && opens > closes) testBlockDepth = braceDepth + 1;
    braceDepth += opens - closes;
    if (testBlockDepth !== null && braceDepth < testBlockDepth) testBlockDepth = null;
  });
  flush();
  return { segments };
}

/** Scan one Zig source file, preserving function attribution and test exclusion. */
export function scanIdentifierConstructors(
  source,
  rel,
  allowlist = ALLOWLIST,
  pinnedAllowCounts = PINNED_ALLOW_COUNTS,
) {
  const { segments } = sourceSegments(source);
  const violations = [];
  const usedAllow = new Set();
  const usedAllowCounts = new Map();

  const record = (segment, lineStarts, offset, what) => {
    const relativeLine = lineAtOffset(lineStarts, offset);
    const line = segment.startLine + relativeLine;
    const key = `${rel}::${enclosingFn(segment.lines, relativeLine)}`;
    if (allowlist[key]) {
      const count = (usedAllowCounts.get(key) ?? 0) + 1;
      usedAllowCounts.set(key, count);
      const expected = pinnedAllowCounts.get(key);
      if (expected !== undefined && count > expected) {
        violations.push(`${rel}:${line + 1} (${key}) — pinned 허용 개수 ${expected}곳 초과`);
        return;
      }
      usedAllow.add(key);
      return;
    }
    violations.push(`${rel}:${line + 1} (${key}) — ${what}`);
  };

  for (const segment of segments) {
    const segmentSource = segment.lines.join('\n');
    const lineStarts = [0];
    for (let i = 0; i < segmentSource.length; i++) {
      if (segmentSource[i] === '\n') lineStarts.push(i + 1);
    }
    const identifierTagAliasesByScope = identifierTagAliases(segmentSource, segment, lineStarts);

    const tagAssignments = /\.tag\s*=(?!=|>)/g;
    for (const assignment of segmentSource.matchAll(tagAssignments)) {
      const expressionStart = assignment.index + assignment[0].length;
      const expressionEnd = tagExpressionEnd(segmentSource, expressionStart);
      const expression = segmentSource.slice(expressionStart, expressionEnd);
      const enumLiteral = new RegExp(`\\.(${IDENTIFIER_TAGS.join('|')})\\b`, 'g');
      let foundIdentifierTag = false;
      for (const literal of expression.matchAll(enumLiteral)) {
        const tag = literal[1];
        record(segment, lineStarts, expressionStart + literal.index, `${tag} 직접 생성`);
        foundIdentifierTag = true;
      }
      if (!foundIdentifierTag) {
        const aliasName = expression.trim().match(/^([A-Za-z_][A-Za-z0-9_]*)$/)?.[1];
        if (aliasName !== undefined) {
          const line = lineAtOffset(lineStarts, assignment.index);
          const fn = enclosingFn(segment.lines, line);
          const localKey = `${fn}::${aliasName}`;
          const localBinding = identifierTagAliasesByScope.bindings
            .get(localKey)
            ?.findLast((entry) => entry.offset < assignment.index);
          const globalBinding =
            localBinding === undefined
              ? identifierTagAliasesByScope.bindings.get(`<top>::${aliasName}`)?.at(-1)
              : undefined;
          const binding = localBinding ?? globalBinding;
          const aliasKey = localBinding === undefined ? `<top>::${aliasName}` : localKey;
          const alias =
            binding === undefined
              ? undefined
              : identifierTagAliasesByScope.aliases
                  .get(aliasKey)
                  ?.findLast((entry) => entry.offset === binding.offset);
          if (alias !== undefined) {
            record(segment, lineStarts, expressionStart, `${alias.tag} 간접 식별자 태그 직접 생성`);
          }
        }
      }
    }

    const calls = /\bmakeBindingIdentifier\s*\(/g;
    for (const call of segmentSource.matchAll(calls)) {
      const prefix = segmentSource.slice(0, call.index);
      // Function declarations are definitions, not calls to the raw helper.
      if (/\bfn\s+$/.test(prefix)) continue;
      record(segment, lineStarts, call.index, 'makeBindingIdentifier 직접 호출');
    }
  }

  return { violations, usedAllow, usedAllowCounts };
}

function runAudit() {
  const violations = [];
  const usedAllow = new Set();
  const usedAllowCounts = new Map();
  for (const file of walk(scanRoot, [])) {
    const rel = relative(root, file);
    const result = scanIdentifierConstructors(readFileSync(file, 'utf8'), rel);
    violations.push(...result.violations);
    for (const key of result.usedAllow) usedAllow.add(key);
    for (const [key, count] of result.usedAllowCounts) {
      usedAllowCounts.set(key, (usedAllowCounts.get(key) ?? 0) + count);
    }
  }

  const stale = Object.keys(ALLOWLIST).filter((key) => !usedAllow.has(key));
  const wrongPinnedCounts = [...PINNED_ALLOW_COUNTS].filter(
    ([key, expected]) => (usedAllowCounts.get(key) ?? 0) !== expected,
  );
  for (const [key, expected] of wrongPinnedCounts) {
    violations.push(
      `${key} — pinned 허용 개수 불일치 (expected ${expected}, actual ${usedAllowCounts.get(key) ?? 0})`,
    );
  }
  if (violations.length > 0) {
    console.error(
      `식별자 직접 생성 ${violations.length}곳 — 분류된 생성 함수를 쓰세요 (scripts/audit-identifier-constructors.mjs 머리말 참고):`,
    );
    for (const violation of violations) console.error(`  ${violation}`);
  }
  if (stale.length > 0) {
    console.error(`ALLOWLIST 의 쓰이지 않는 항목(지우세요): ${stale.join(', ')}`);
  }
  if (violations.length > 0 || stale.length > 0) process.exit(1);
  console.log(`identifier constructor audit OK (허용 ${usedAllow.size}곳)`);
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : null;
if (invokedPath === import.meta.url) runAudit();
