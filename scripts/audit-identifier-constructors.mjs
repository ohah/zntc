#!/usr/bin/env node
// 트랜스포머 식별자 생성 audit (#4760 3단계).
//
// 배경: 트랜스포머가 사용자 변수를 가리키는 식별자를 새로 만들면서 "어느 변수인지"(심볼)를 빠뜨리면
// 그 노드만 옛 이름으로 나가거나 minify 가 다른 변수와 묶는다(#4703·#4712·#4762·#4763). 지점별로
// 고치면 새 변환이 들어올 때마다 같은 누락이 생긴다. 그래서 식별자는 **무엇을 가리키는지 고르는**
// 생성 함수로만 만든다:
//   - 사용자 변수: makeIdentifierRefWithSymbol(At) · makeUserRefNamed · makeCurrentClassRef ·
//                  makeRootScopeRef · makeUserBinding  (심볼 전달)
//   - 합성 이름:   makeSyntheticRef(FromSpan/At) · makeSyntheticBinding · makeTempVarRef ·
//                  makeRuntimeHelperRef
//   - 전역:        makeGlobalRef(FromSpan/At)
//   - 속성 이름:   makePropertyName(FromSpan/At)
//
//   - JSX:         makeSyntheticJsxTag · makeJsxAttributeName  (사용자 컴포넌트 태그는 원본 노드를 옮긴다)
//
// 규칙: src/transformer 안에서 identifier_reference / binding_identifier / jsx_identifier 노드를 직접
// 만드는 곳(`.tag = if (…) … else .identifier_reference` 같은 조건식 포함)과 `makeBindingIdentifier(`
// 호출은 아래 ALLOWLIST 의 함수 안에서만 허용한다. 등록 안 된 곳이 있으면 CI 실패.
//
// 대상 밖(의도): `private_identifier`(`#x`) 는 스코프 심볼이 아니다. AST 플러그인(`ast_plugin.zig`)은
// 외부 API 라 임의 노드를 만든다 — 플러그인이 만든 식별자의 이름은 변환 뒤 재분석(minify·번들)이 정한다.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve, relative } from 'node:path';

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
  'src/transformer/transformer/node_helpers.zig::makeUserBinding':
    '사용자 바인딩 생성 함수(심볼 전달)',
  'src/transformer/es_helpers.zig::jsxIdentifierNode':
    'makeSyntheticJsxTag·makeJsxAttributeName 의 공통 노드 생성',
};

const PATTERNS = [
  // `.tag = X` 뿐 아니라 `.tag = if (c) .a else .identifier_reference` 도 잡는다(`==` 비교는 제외).
  { re: /\.tag\s*=(?!=)[^,;]*\.identifier_reference\b/, what: 'identifier_reference 직접 생성' },
  { re: /\.tag\s*=(?!=)[^,;]*\.binding_identifier\b/, what: 'binding_identifier 직접 생성' },
  { re: /\.tag\s*=(?!=)[^,;]*\.jsx_identifier\b/, what: 'jsx_identifier 직접 생성' },
  { re: /\bmakeBindingIdentifier\(/, what: 'makeBindingIdentifier 직접 호출' },
];

function walk(dir, out) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (name.endsWith('.zig') && !name.endsWith('_test.zig')) out.push(p);
  }
  return out;
}

// line index 위로 올라가며 가장 가까운 `fn name(` 선언을 찾는다(여러 줄 선언도 첫 줄에 이름이 있음).
function enclosingFn(lines, i) {
  for (let j = i; j >= 0; j--) {
    const m = lines[j].match(/\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/);
    if (m) return m[1];
  }
  return '<top>';
}

const violations = [];
const usedAllow = new Set();
for (const file of walk(scanRoot, [])) {
  const rel = relative(root, file);
  const lines = readFileSync(file, 'utf8').split('\n');
  lines.forEach((line, i) => {
    const code = line.replace(/\/\/.*$/, '');
    for (const { re, what } of PATTERNS) {
      if (!re.test(code)) continue;
      // 함수 정의 줄 자신(`fn makeBindingIdentifier(`)은 호출이 아니다.
      if (/\bfn\s+makeBindingIdentifier\(/.test(code)) continue;
      const key = `${rel}::${enclosingFn(lines, i)}`;
      if (ALLOWLIST[key]) {
        usedAllow.add(key);
        continue;
      }
      violations.push(`${rel}:${i + 1} (${key}) — ${what}`);
    }
  });
}

const stale = Object.keys(ALLOWLIST).filter((k) => !usedAllow.has(k));
if (violations.length > 0) {
  console.error(
    `식별자 직접 생성 ${violations.length}곳 — 분류된 생성 함수를 쓰세요 (scripts/audit-identifier-constructors.mjs 머리말 참고):`,
  );
  for (const v of violations) console.error(`  ${v}`);
}
if (stale.length > 0) {
  console.error(`ALLOWLIST 의 쓰이지 않는 항목(지우세요): ${stale.join(', ')}`);
}
if (violations.length > 0 || stale.length > 0) process.exit(1);
console.log(`identifier constructor audit OK (허용 ${usedAllow.size}곳)`);
