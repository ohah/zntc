# ZTS - Zig TypeScript Transpiler

Zig로 작성하는 JS/TS/Flow 트랜스파일러 + 번들러 (SWC/oxc 수준 목표).
C NAPI 바인딩으로 Node.js/Bun에서 in-process 사용, Vite/Rollup 플러그인 어댑터 지원.

## Tech Stack
Zig 0.15.2 · C NAPI v8 (vendor/node-api-headers/) · Node.js 24+ / Bun 1.3+ · mise · `zig build`

## Documentation
- [docs/USAGE.md](./docs/USAGE.md) — CLI 실행법, `@zts/core` JS API, 플랫폼/watch/ES 타겟/CSS 동작 포인트
- [docs/STRUCTURE.md](./docs/STRUCTURE.md) — 디렉토리 구조
- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — 파이프라인 아키텍처
- [docs/ROADMAP.md](./docs/ROADMAP.md) — Phase 현황, 성능, 미지원, 기술부채
- [docs/TESTING.md](./docs/TESTING.md) — Test262, 유닛/통합/스모크 테스트
- [docs/BUNDLER.md](./docs/BUNDLER.md), [docs/PLUGINS.md](./docs/PLUGINS.md), [docs/HMR.md](./docs/HMR.md), [docs/DECISIONS.md](./docs/DECISIONS.md), [docs/FLOW.md](./docs/FLOW.md)
- [docs/BACKLOG.md](./docs/BACKLOG.md), [docs/ISSUES.md](./docs/ISSUES.md), [docs/AST_PLUGINS.md](./docs/AST_PLUGINS.md)
- CLI 옵션 전체: `zts --help` / JS API 구현: `packages/core/index.ts`

## Development Workflow
1. 작업 단위 작게 (하나의 PR = 하나의 기능)
2. 독립 작업은 서브에이전트로 병렬
3. main 직접 push 금지 — feature branch → PR → merge
4. PR 올리기 **전** `/simplify` 필수 (파일 간 상호작용까지 검토 → 이후 PR 생성)
5. `gh pr create` 시 `--label`, `--assignee` 항상 지정
6. Zig 초보자에게 설명 포함

## Memory ownership
- **Arena 안 리소스는 개별 deinit 금지**. `arena_alloc`으로 만든 `DynamicBitSet`/`ArrayList` 등은 `arena.deinit()`이 일괄 해제. 개별 `defer X.deinit()`을 함께 걸면 `arena.deinit()` 이후에 실행되어 해제된 메모리 접근 → segfault (#1287).
- 성공 경로에서 `arena.deinit()`을 명시 호출하지 말 것. `defer arena.deinit()` 하나로 충분.
- `errdefer arena.deinit()`만 쓰고 성공 경로는 따로 관리하는 패턴은 위험 — defer 순서 실수 유발.

PR 제목: `feat(lexer): add numeric literal tokenization` 형식.

## References
Bun (src/js_parser.zig, js_lexer.zig) · oxc · SWC · esbuild · Hermes (Flow) · Metro (RN) · TypeScript · Test262 · tc39.es/ecma262
