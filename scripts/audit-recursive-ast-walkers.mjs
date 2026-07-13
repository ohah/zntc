#!/usr/bin/env node
// 재귀 AST walker durability audit (#4123).
//
// 배경: `a + b + c + … (수천 항)` 같은 깊은 좌결합 트리를 AST visitor 가 재귀로 내려가면
// 스택 오버플로우(#4123). 대책으로 핫패스/공통 walker 를 `ast_walk.walkPreorderIterative`
// (명시 스택 반복 순회)로 전환했다. 문제는 **새 walker 가 또 재귀로 children() 을 돌면 버그가
// 조용히 재유입**된다는 것. 이 audit 이 그 tripwire 다.
//
// 규칙: src/ 안의 모든 `ast_walk.children()` 호출처(주석/정의 제외)는 아래 ALLOWLIST 의
// 한 분류에 *명시적으로* (file::fn 키로) 등록돼야 한다. 등록 안 된 신규 호출처가 있으면 CI 실패.
//   - iterative_safe   : 명시 스택/큐/collector 또는 sanctioned 헬퍼(walkPreorderIterative).
//                        깊이 무관 안전.
//   - one_level        : 재귀 없이 직계 자식만 1단계 순회(flat). 깊이 무관 안전.
//   - recursive_tracked: 아직 재귀라 깊은 체인서 overflow 가능. #4123 PR-2c 에서 반복화 예정.
//                        (전환되면 children() 대신 walkPreorderIterative 를 써 이 목록에서 빠짐.)
//
// 신규 walker 작성자에게: 서브트리를 재귀 순회해야 하면 **반드시 walkPreorderIterative** 를
// 써라(또는 명시 스택). 직계 1단계만 보면 one_level 로, 깊이 가드(cap)가 있으면 그 함수에
// 가드 주석을 달고 iterative_safe 로 등록하라.
//
// 한계(정직히): 이 audit 은 `ast_walk.children()` 기반 일반 순회만 본다. binary/unary 노드의
// left/right 를 *직접* 재귀(visitBinaryNode/emitBinary 식 rebuild/emit)하는 특수 패턴, 그리고
// depth-cap 이 달린 direct-recursion evaluator(purity/import_scanner 등)는 이 audit 밖이다 —
// 전자는 좌-스파인 평탄화(#4123 PR-1), 후자는 자체 depth guard 로 안전. 키를 file::fn 으로 둬
// 동명 walker 우회를 막고, fn 선언이 여러 줄로 쪼개져도(`fn name(\n …)`) 잡도록 한다.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve, relative } from "node:path";

const root = resolve(import.meta.dirname, "..");
const srcRoot = join(root, "src");

// "<relpath>::<fn>" → { class, note }. class ∈ {iterative_safe, one_level, recursive_tracked}.
// 파일 경로로 스코프해 동명 walker 가 분류를 상속하는 false-negative 를 차단.
const ALLOWLIST = {
  // --- sanctioned 헬퍼 / 명시 스택·큐·collector (깊이 무관 안전) ---
  "src/parser/ast_walk.zig::walkPreorderIterative": { class: "iterative_safe", note: "the sanctioned iterative helper" },
  "src/parser/ast_walk.zig::collectChildrenInto": { class: "iterative_safe", note: "sanctioned child-collection entry point for iterative worklists (#4123 PR-2c)" },
  "src/bundler/emitter/dead_store.zig::stmtBreaksFlow": { class: "iterative_safe", note: "명시 스택(worklist)으로 서브트리 순회 — 두 store 사이 statement 가 바깥 흐름을 끊는지 판정 (#4503). 재귀 없음." },
  "src/parser/ast_walk.zig::collectReachableNodeIndices": { class: "iterative_safe", note: "explicit stack worklist" },
  "src/transformer/minify.zig::markReachableNodes": { class: "iterative_safe", note: "BFS queue" },
  "src/transformer/es2015_block_scoping.zig::collectChildIndices": { class: "iterative_safe", note: "one-level collector feeding caller stack" },
  "src/transformer/transformer/worklet.zig::collectAllIdentifiers": { class: "iterative_safe", note: "explicit stack (worklet)" },
  "src/transformer/transformer/worklet.zig::collectNewExpressionCallees": { class: "iterative_safe", note: "explicit stack (worklet)" },
  "src/transformer/transformer/worklet.zig::walkBodyForClosureAnalysis": { class: "iterative_safe", note: "explicit stack; nested-fn depth bounded by source nesting" },
  "src/bundler/tree_shaker/const_materialize.zig::anyReachableNode": { class: "iterative_safe", note: "numeric_dfs_stack" },

  // --- 직계 1단계만 (재귀 없음) ---
  "src/bundler/runtime_polyfills.zig::markSkippedIdentifiers": { class: "one_level", note: "import/export specifiers only, flat outer loop" },
  "src/bundler/constant_facts.zig::markMinifySensitiveIdentifierRefs": { class: "one_level", note: "one level, flat outer for" },

  // --- recursive_tracked: 없음 ---
  // #4123 PR-2c 에서 마지막 6개 재귀 walker(walkFunctionVarBindingPatterns / scanChildrenForUnsupportedBindingLiteShadow /
  // markBindingLiteValueUses / rewriteAwaitToYieldAwait / visitTypeContextNode / hasRawPrivateSyntax)를 전부 반복화했다.
  // 이들은 이제 children() 을 직접 호출하지 않고 `ast_walk.collectChildrenInto`(또는 walkPreorderIterative)를 경유하므로
  // 이 audit 의 children() 호출처 목록에서 사라진다 → recursive_tracked=0. 새 재귀 walker 가 children() 을 직접 돌면
  // 미분류 violation 으로 다시 잡힌다.
};

function listZigFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    const st = statSync(p);
    if (st.isDirectory()) out.push(...listZigFiles(p));
    else if (entry.endsWith(".zig")) out.push(p);
  }
  return out;
}

// fn 선언: 이름만 매칭(여는 괄호를 같은 줄에 요구하지 않음 → 여러 줄 시그니처도 잡음).
// `fn (` (익명 fn 타입/포인터)은 이름이 없어 매칭 안 됨.
const FN_DECL = /\bfn\s+([A-Za-z_][A-Za-z0-9_]*)/;
// children( 호출. ast_walk.children( 또는 bare children(ast/children(self.ast.
const CALL = /(?:ast_walk\.)?\bchildren\s*\(/;

// Zig 은 라인 주석(`//`)만 있고 블록 주석이 없다. trailing 주석을 잘라 false-positive 차단.
// (children() 가 문자열 리터럴 안에 등장하는 일은 없어 단순 strip 으로 충분.)
function stripLineComment(line) {
  const i = line.indexOf("//");
  return i === -1 ? line : line.slice(0, i);
}

const callSites = [];
for (const file of listZigFiles(srcRoot)) {
  if (file.endsWith("_test.zig")) continue; // 테스트 파일만 제외(경로 substring 아님)
  const rel = relative(root, file).split("\\").join("/");
  const lines = readFileSync(file, "utf8").split("\n");
  let curFn = "<file-scope>";
  for (let i = 0; i < lines.length; i++) {
    const code = stripLineComment(lines[i]);
    const fnMatch = code.match(FN_DECL);
    if (fnMatch) curFn = fnMatch[1];
    if (!CALL.test(code)) continue;
    if (/\bfn\s+children\s*\(/.test(code)) continue; // children() 정의 자체
    callSites.push({ key: `${rel}::${curFn}`, file: rel, line: i + 1, fn: curFn });
  }
}

const violations = [];
const byClass = { iterative_safe: 0, one_level: 0, recursive_tracked: 0 };
const matchedKeys = new Set();
for (const site of callSites) {
  const entry = ALLOWLIST[site.key];
  if (!entry) {
    violations.push(site);
  } else {
    byClass[entry.class]++;
    matchedKeys.add(site.key);
  }
}

console.log(`recursive-ast-walker audit: ${callSites.length} children() 호출처 검사`);
console.log(
  `  iterative_safe=${byClass.iterative_safe}  one_level=${byClass.one_level}  recursive_tracked=${byClass.recursive_tracked}`,
);

if (violations.length > 0) {
  console.error("\n❌ 분류되지 않은 ast_walk.children() 호출처:");
  for (const v of violations) console.error(`  ${v.file}:${v.line}  fn ${v.fn}`);
  console.error(
    "\n새 AST 서브트리 순회는 깊은 좌결합 체인(#4123)에서 스택 오버플로우를 일으킬 수 있습니다.\n" +
      "- 재귀 순회면 `ast_walk.walkPreorderIterative` 로 쓰세요(명시 스택).\n" +
      "- 직계 1단계만 보면, 또는 깊이 가드가 있으면, scripts/audit-recursive-ast-walkers.mjs 의\n" +
      "  ALLOWLIST 에 `<relpath>::<fn>` 키로 분류(class)+근거(note)와 함께 등록하세요.",
  );
  process.exit(1);
}

// stale(매칭 0) ALLOWLIST 항목 알림 — PR-2c 전환으로 children() 미사용이 된 항목 정리용(실패 아님).
const stale = Object.keys(ALLOWLIST).filter((k) => !matchedKeys.has(k));
if (stale.length > 0) {
  console.log(`\n  ℹ️ 매칭 0 인 ALLOWLIST 항목(전환 완료/이동 — 정리 가능):`);
  for (const k of stale) console.log(`     ${k}`);
}

// 아직 재귀인 walker 가시화 — green CI 가 "재귀 walker 없음"으로 오인되지 않도록(실패 아님).
if (byClass.recursive_tracked > 0) {
  console.log(
    `\n  ⚠️ recursive_tracked ${byClass.recursive_tracked}개 — 깊은 체인서 여전히 overflow 가능(#4123 PR-2c 대기). green=전환완료 아님.`,
  );
} else {
  console.log("  ✅ recursive_tracked 0 — #4123 walker 전환 완료. ALLOWLIST 의 recursive_tracked 항목 정리 가능.");
}

console.log("✅ 모든 children() 호출처가 분류됨 (신규 재귀 walker 재유입 차단).");
