# Test Suite

## Test262 (TC39 정합성)
```bash
zig build test262                        # 러너 자체 유닛 테스트
zig build test262-run                    # 전체 실행 (50,504건, pass-rate 측정)
zig build test262-run -- --filter=language  # 언어 기능만
zig build test262-run -- --verbose       # 상세 출력
```
- 결과 (2026-04-29 기준): **50,504 / 50,504 통과 (0 fail, 100%)**
- 러너 위치: `src/test262/`, 입력 서브모듈: `tests/test262/`
- excludelist: 엔진 의존 / 스펙 외 항목만 (현재 0건)

## 유닛 테스트 (Zig)
```bash
zig build test                           # 모든 모듈 유닛 + 통합 Zig 테스트
```
주요 테스트 파일은 `*_test.zig` 로 분리되어 모듈별 디렉토리에 함께 위치.

| 영역 | 위치 | 비고 |
|------|------|------|
| 렉서 | `src/lexer/{scanner,token,unicode}_test.zig` | 토큰/유니코드 ID/JSX |
| 파서 | `src/parser/{parser,ast,ast_walk}_test.zig` | AST 24B layout, walker identity |
| 의미 분석 | `src/semantic/{analyzer,checker,scope,symbol}_test.zig` | Reference flags, hoisting |
| 트랜스포머 | `src/transformer/{transformer,minify,worklet*}_test.zig` | 다운레벨/미니파이 |
| 코드젠 | `src/codegen/codegen_test/*.zig` + `mangler_test.zig`, `sourcemap_test.zig` | E2E 출력 어서션 |
| 번들러 | `src/bundler/bundler_test/*.zig` + 모듈별 `*_test.zig` | 통합 + unit |
| 정규식 | `src/regexp/{parser,ast,flags,unicode_property}_test.zig` | regex AST/플래그 |
| 서버 | `src/server/{dev_server,file_watcher,mime}_test.zig` | HTTP/HMR/MIME |
| 회귀 | `src/test_regression.zig` | 라운드 1/2/4 광역 fuzz 영구 보존 |
| DTO sync | `src/config_options_dto_test.zig` | Zig DTO ↔ TS BuildOptions 필드 검증 |

## 통합 테스트 (Bun)
```bash
cd tests/integration && bun test         # CLI/NAPI 통합 테스트
cd tests/e2e && bun test                 # Playwright E2E (dev server, 브라우저)
```

### 실 라이브러리 fixture
- 루트 `bun install` 로 `clsx`/`nanoid`/`zod`/`react`/`react-dom`/`preact`/`immer`/`date-fns`/`rxjs`/`lodash-es` 등 자동 설치 → `manual-chunks-smoke` / `inline-dynamic-imports-smoke` 의 `test.skipIf(!hasPackage(...))` 통과.
- **emotion v10** 은 v11 과 동일 트리에 공존 불가 → 별도 격리 install 필요:
  ```bash
  cd tests/integration/fixtures/emotion-v10 && bun install
  ```
  미설치 시 `emotion-v10.test.ts` 의 `describe.skipIf(!hasV10)` 로 전체 skip.

`tests/integration/tests/` 주요 스위트 (총 60+):

**번들러 / 코드젠**
- `bundle-smoke.test.ts` — 번들 스모크 (다중 케이스)
- `bundle-circular-cycle.test.ts` / `bundle-dynamic-import.test.ts` — 순환 / dynamic import
- `tree-shake-precision.test.ts` / `const-value-inline.test.ts` / `export-preserve-minify.test.ts`
- `inline-dynamic-imports{,-smoke}.test.ts` / `manual-chunks{,-smoke}.test.ts` / `preserve-modules.test.ts`
- `runtime-helpers.test.ts` / `runtime-helper-virtual-module.test.ts`
- `mangler-minify.test.ts` / `minify-orphan-dead-store.test.ts`

**소스맵**
- `sourcemap.test.ts` / `sourcemap-footer.test.ts` / `round4-sourcemap.test.ts`

**ES 타겟 / Hermes / RN**
- `downlevel.test.ts` / `downlevel-edge.test.ts`
- `compat-table.test.ts` (kangax ES5~ES2022, 237 subtests) + `compat-table-extract.cjs`
- `swc-compare.test.ts` (29 cases × 9 targets)
- `es5-rn.test.ts` / `es5-call-super.test.ts` / `es5-class-super-shared-node.test.ts` / `es5-stage3-decorator.test.ts`
- `hermes-runtime.test.ts` / `polyfill-rbm.test.ts` / `rn-refresh-prelude.test.ts` / `node-compat.test.ts`

**Flow / RSC / 데코레이터**
- `flow-rn.test.ts` / `flow-component-react-ref.test.ts`
- `rsc-directives.test.ts`
- `stage3-decorator{,-smoke}.test.ts`

**dev 서버 / HMR / watch**
- `devserver.test.ts` / `devserver-sse-mcp.test.ts` / `hmr.test.ts`
- `watch-json.test.ts` / `watch-stress.test.ts`

**Resolve / 외부 호환**
- `resolve-fallback.test.ts` / `browser-field.test.ts` / `block-list.test.ts`
- `vite-plugin-zts.test.ts` / `zts-config-bundler.test.ts`

**ESM / namespace / semantic 회귀**
- `esm-enum-hoisting.test.ts` / `esm-function-hoist.test.ts`
- `ns-shadow-runtime.test.ts` / `ns-var-collision.test.ts`
- `semantic-{arrow-var-hoist,block-function-hoist,lexical-hoist}.test.ts`

**Profile / 진단 / asset**
- `profile-flags.test.ts` / `profile-parity.test.ts` / `bench.test.ts`
- `ast-info-preservation.test.ts` / `asset-registry.test.ts`
- `strict-execution-order.test.ts` / `stop-after.test.ts` / `batch-e-cli.test.ts`

**광역 fuzz 회귀** (Zig 유닛에 영구 보존)
- `round1-fuzz.test.ts` / `round2-fuzz.test.ts` — 라운드 1/2 회귀

**TypeScript 컴파일러 케이스 (36개)**
- `tests/integration/tests/tsc/` — `classes`, `enums`, `decorator`, `es2021`~`es2025`, `es6-*`, `generators`, `expressions`, `ts-import-equals`, `ast-layout-snapshots` 등

**CSS**
- `css-bundle.test.ts` (@import 체인, 순환, 중복 제거, BOM, 대용량)
- `css-library-smoke.test.ts` (Emotion, Styled-Components, 네이티브 CSS)

`tests/e2e/tests/` (Playwright):
- `smoke.test.ts` / `browser-smoke.test.ts` — 브라우저 번들 실행
- `sourcemap-e2e.test.ts` — 브라우저 stack trace 매핑
- `vite-app-e2e.test.ts` / `zts-app-builder-e2e.test.ts` — Vite/zts.app 빌더

## 스모크 테스트 (실제 패키지 빌드)
```bash
cd tests/benchmark && bun run smoke.ts          # 144 케이스 빌드+실행 검증 (vs esbuild/rolldown/rspack)
bun run smoke.ts -- --filter=react              # 특정 패키지만
bun run smoke.ts -- --keep-output               # 산출물 보존 (디버깅)
```
- esbuild 출력을 baseline 으로 ZTS / rolldown / rspack 출력 일치 검증
- 빌드 성공 + 실행 성공 + 출력 일치 3단 어서션
- `smoke-diagnostics.test.ts` — 결과를 통합 테스트에서 다시 회귀 어서션

## 번들 perf 회귀 가드
```bash
# 비교 모드 — baseline 대비 ±15% 초과 시 fail
bun run tests/benchmark/bundle-perf.ts

# baseline 갱신 (의도적 perf 변경 시)
bun run tests/benchmark/bundle-perf.ts --write
```
- fixture 3종 (small 10 / medium 100 / large 200 모듈, externals 포함)
- 워밍업 5회 + 측정 20회 → median 비교
- baseline: `tests/benchmark/baselines/bundle-perf.json` (commit 됨)
- 머신 의존 — 절대값은 머신마다 다름. dev 머신 비교는 의미 있음, CI 절대값은 다름
- CI: `benchmark.yml` 가 PR 마다 `--no-fail --output` 으로 실행 → JSON artifact 업로드 (트렌드 추적, 회귀 fail 안 함)

## 기타 벤치 / 분석
- `bench.ts` / `pipeline.ts` — 합성 벤치 (200 모듈, 단계별 시간)
- `napi-bench.ts` — NAPI 콜백 hot-path (`zig build bench-callback` 와 한 쌍)
- `minify-bench.ts` / `size-gap.ts` / `tree-shake-size.ts` — 사이즈/미니파이 vs esbuild/rolldown
- `mangler-property.ts` — property mangler 안정성 fuzz
- `transpile-conformance.ts` — TS strip + 다운레벨 정합성

## 통합 테스트 실행 위치
- 통합 테스트는 항상 `tests/integration/` cwd 에서 실행. 루트에서 `bun test` 하면 fixture 경로가 어긋나서 깨짐.
- e2e 도 `tests/e2e/` cwd 에서. Playwright 가 자체 server fixture 를 띄움.

## CI
- `.github/workflows/` — `ci.yml` (zig + integration), `benchmark.yml` (perf 트렌드)
- ReleaseFast 빌드에서만 깨지는 회귀가 존재 → debug 통과해도 CI 실패 시 `-Doptimize=ReleaseFast` 로 로컬 재현 필수
