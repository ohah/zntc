## Summary

<!-- 변경 사항을 1-3줄로 요약 -->

## Changes

<!-- 주요 변경 내용을 목록으로 -->
-

## Test Plan

<!-- 어떻게 테스트했는지 -->
- [ ] `zig build test` 통과
- [ ] `zig fmt --check src/` 통과
- [ ] 관련 Test262 케이스 확인 (해당 시)

## Decision Impact

<!-- DECISIONS.md의 미결정 사항에 영향을 주는 경우 기술 -->
None

## AST 신규 노드 체크리스트 (해당 시)

<!-- 새 AST Tag/노드를 추가한 PR이라면 docs/design/AST_NEW_NODE_CHECKLIST.md 참고 -->
- [ ] Tag enum + data 변종 (`src/parser/ast.zig`)
- [ ] 파서 (`src/parser/{statement,expression,declaration}.zig`)
- [ ] 코드젠 (`src/codegen/codegen.zig`) — minify 포함
- [ ] 트랜스포머 visit (`src/transformer/transformer.zig`)
- [ ] 번들러 통합 (`binding_scanner.zig` / `tree_shaker.zig` / `statement_shaker.zig`)
- [ ] AST plugin 노출 (`src/transformer/ast_plugin.zig`)
- [ ] 단위 + 통합 + Test262 회귀
- [ ] 문서 (doc-comment + ROADMAP)
