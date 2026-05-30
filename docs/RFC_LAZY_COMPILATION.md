# RFC: Lazy Compilation — dev 서버 온디맨드 청크 컴파일

상태: **DRAFT · 구현 착수(PR 연쇄)** · 분류: dev UX / bundler
관련: `src/server/dev_server.zig`, `src/bundler/bundler.zig`, `src/bundler/chunk.zig`, `src/bundler/emitter/chunks.zig`, `src/bundler/emitter.zig`, `src/bundler/linker.zig`, `src/bundler/runtime_helpers.zig`

## 1. 배경

ZNTC dev 서버는 시작 시 전체 모듈 그래프를 parse → transform → codegen → emit 하고
(`dev_server.zig` `watchLoop` → `inc_bundler.rebuild()`, `:713`), `/bundle.js` 요청마다
fresh `Bundler.bundle()` 로 전체를 다시 번들한다 (`dev_server.zig:1287` `serveBundle`).
라우트 기반 code splitting 앱에서도 **진입조차 안 한 route 의 코드를 시작 시 전부 컴파일**하므로
cold-start 가 느리다 (실측 CLI dev lodash 307~398ms — RFC #3931 측정).

webpack `experiments.lazyCompilation` / rspack lazy compilation 처럼 **브라우저가 실제로 요청하는
청크만 온디맨드로 컴파일**해 dev cold-start 를 줄이는 것이 목표다. (로드맵 "Lazy compilation = 미구현"
항목의 실제 구현.)

### 1.1 현재 emit 분기 — dev 와 splitting 이 상호배타

`bundler.zig` `bundle()` 의 emit 분기:

- `:1594` `if (dev_mode)` → **단일 번들** (`emitWithTreeShaking`, `__commonJS`/`__esm` 래핑 + HMR 런타임).
- `:1625` `else if (code_splitting or preserve_modules)` → **per-chunk** (`emitChunks`).

두 경로는 **상호배타**다. dev 는 항상 단일 `/bundle.js` (HTML `<script type="module" src="/bundle.js">`
`dev_server.zig:1444`). 그리고 **`emitChunks` 는 dev/HMR 을 전혀 모른다** (`emitter/chunks.zig` 에
`dev_mode`/`collect_module_codes`/`react_refresh`/make-hot 0건). 즉 lazy 의 본체는 **chunk emit 경로에
dev HMR 런타임을 이식**해 `dev_mode + code_splitting` 조합을 성립시키는 작업이다.

### 1.2 선행 게이트 — RFC #3940 은 GREEN

청크를 나중에 재컴파일하려면 심볼 rename 이 graph 에 박혀 있으면 안 된다(stale). `linker.zig:175`
`rename_table` 가 이미 **build-scope 단일 store** 로 이행 완료(RFC #3940 L.5c — `Symbol.canonical_name`
field 제거됨). `getCanonicalName` 이 `rename_table` 만 조회(`:1392-1400`). → **lazy 의 토대가 이미 깔려
있음.** 단 `rename_table` 는 Linker 소유(build-scope deinit) 이므로, **lazy dev 는 Linker(+graph)를
세션 동안 살려둬야** 온디맨드 emit 이 rename 을 읽는다 — `IncrementalBundler` 가 graph 를 빌드 간
유지하는 패턴(`incremental.zig`)을 그대로 따른다.

RFC #3933 (graph persistence) 은 NO-GO 였으나, 본 MVP 은 **parse 를 eager** 로 두어(아래 §3) 의존하지 않는다.

## 2. 제안 — "청크 = 첫 GET 시 컴파일" 통일 모델

ZNTC dev 서버는 **모든 청크 URL 라우트를 직접 제어**한다. 따라서 webpack 식 proxy 모듈 없이
**dev 서버 라우트 핸들러 자체가 lazy 백엔드**가 된다.

1. **시작 시 (전역 1회, cheap)**: 전체 그래프 parse/discover + 청크 배치(`chunk.zig`) +
   cross-chunk 심볼 인터페이스 계산(`computeCrossChunkLinks`, per-chunk `computeRenamesForModules`).
   → 청크 그래프(청크→모듈, 안정적 청크 이름, 청크 간 export 이름 계약)만 확정. **transform/codegen/emit 안 함.**
2. **청크 첫 GET 시 (per-chunk, 온디맨드)**: 해당 청크 모듈집합만 transform(미수행 시) → codegen → emit
   → 캐시 → 응답.
   - entry 청크: HTML `<script src="/bundle.js">` 첫 로드가 트리거 (= lazy entry).
   - 동적 청크: 런타임 `__zntc_load_chunk("<chunk>.js")`(`runtime_helpers.zig:232`)의 `<script>` GET 이
     트리거 → 기존 동적 import 런타임 그대로 재사용, **클라이언트 변경 거의 없음**.
3. **watch/HMR**: 변경 파일이 **이미 활성화된** 청크 소속이면 그 청크만 재컴파일 후 HMR push;
   **미활성** 청크 소속이면 캐시 invalidate 만(컴파일 안 함).

핵심: 시작 시 **비싼 per-module 작업(transform/codegen/emit)을 건너뛰고**, 청크 그래프와 심볼 계약
(상대적으로 cheap)만 확정 → cross-chunk 이름 불안정 문제를 구조적으로 회피.

webpack 은 proxy 모듈 + XHR 활성화 미들웨어(`/_rspack/lazy/trigger`)가 필요하지만, ZNTC dev 서버는
임의 청크 URL 을 GET 시점에 컴파일할 수 있어 **proxy 도, 별도 활성화 채널도 불필요**하다.

## 3. 결정된 범위 (확정)

- **경계**: entry point + 동적 `import()` **둘 다** lazy (webpack `entries:true, imports:true` 동치).
- **지연 깊이**: **transform/codegen/emit 만 지연**. parse(graph discover)는 시작 시 전체 수행
  (MVP — RFC #3933 NO-GO 의존 회피, 안전).
- **적용 면**: **dev 서버 전용** (`zntc <entry> --serve` / JS `startDevServer`). 프로덕션 빌드 불변.

## 4. 재사용 인프라 (신규 작성 최소화)

- 동적 import = 청크 경계: `chunk.zig:651-664` `addDynamicEntry`. 이미 동작.
- 임의 모듈집합 per-chunk rename: `linker.zig:2525` `computeRenamesForModules(module_indices, occupied_names)`
  + `emitter/chunks.zig:570` (청크별 독립 네임스페이스). code-splitting 경로가 이미 사용.
- cross-chunk 심볼 배선: `bundler.zig:1650` `computeCrossChunkLinks`.
- 런타임 청크 로더: `runtime_helpers.zig:232` `__zntc_load_chunk` (DOM `<script>`/Worker/Node-ESM) +
  `__zntc_register`/`__zntc_require`(`:194,219`). dev/HMR 도 `__zntc_register` 를 공유.
- 모듈 동적 추가·parse 캐시: `incremental.zig`, `graph/build_flow.zig:676` `buildIncremental`,
  `PersistentModuleStore`. 시작 parse + watch 재컴파일에 재사용.
- federation lazy wrapper 선례: `chunk.zig:666-669` (MF expose = 동적 wrapper 재사용) — lazy 청크 변환의 일반화.
- dev 라우팅/HMR: `dev_server.zig:1246` 라우터, `:713` `watchLoop`, WS `/__hmr`.

## 5. 단계별 PR 분할

- **PR-1 (이 RFC)**: RFC 문서 + `lazy_compilation` 내부 옵션 스캐폴딩(`BundleOptions`, `DevServer.Options`).
  동작 변경 없음(옵션 미소비). 후속 PR 의 토대.
- **PR-2 — dev+splitting emit 병합 (크럭스)**: `emitChunks` 가 `dev_mode`(HMR 래핑 + `collect_module_codes`)를
  지원하도록 확장. `bundler.zig` 에 `dev_mode AND code_splitting` 경로 추가. **eager** 로 먼저 동작시켜
  dev code-splitting 자체를 회귀 없이 성립(가장 위험한 단계 — corpus/HMR 가드 필수).
- **PR-3 — 사전계산/온디맨드 emit 분리 + dev 서버 lazy 라우트·캐시**: 시작 시 chunk plan 까지만,
  청크 첫 GET 시 emit. `LazyChunkCache`. 안정적(content-hash 대신 모듈경로 기반) dev 청크 이름.
- **PR-4 — watch/HMR 통합**: 활성/미활성 청크 분기, 그래프 구조 변경 시 사전계산 재실행.
- **PR-5 — 검증/벤치 + 로드맵 갱신 + `--lazy` 사용자 노출**: cold-start 벤치, 로드맵 "미구현" 제거,
  CLI `--lazy`/JS 옵션 공개(메모리 `feedback_default_change_napi_drift` 5곳 동기).

## 6. 핵심 리스크와 완화

- **cross-chunk 심볼 계약 안정성** (L 난이도 핵심): 동적 청크를 나중에 컴파일할 때 entry/shared 청크 export
  심볼 이름을 정확히 참조해야 함. → 심볼 rename·cross-chunk 링크를 **시작 시 전역 1회 확정**(PR-3 사전계산),
  지연은 codegen 문자열/emit 뿐. 이름이 고정돼 청크 컴파일 순서와 무관하게 일관.
- **dev 모드 회귀** (PR-2): 현재 dev = 단일 `/bundle.js`. splitting 을 켜며 런타임 청크 로더/HMR 상호작용에서
  회귀 가능 → 전체 corpus + HMR 통합 테스트 가드, kill-switch(`lazy_compilation=false` 시 기존 경로 100% 보존).
- **Linker 생명주기**: rename_table 가 Linker 소유 → 세션 동안 graph+linker 유지 필요. `IncrementalBundler`
  패턴 재사용으로 해결(이미 graph 를 빌드 간 유지).

## 7. 측정 / 검증

- **cold-start 벤치**: route-split 샘플(entry + `import('./routes/heavy')`)에서 `--serve --lazy` vs `--serve`
  서버 기동~첫 응답 시간. 기대: lazy 시작 시 heavy route 미컴파일(로그), 진입 시 `/<chunk>.js` 첫 GET 에 최초 컴파일.
- **통합 테스트**(`tests/integration` cwd 준수): dev 기동 → `GET /bundle.js`(entry 컴파일·200) → 동적 청크
  URL 캐시 miss 확인 → 그 URL GET(유효 JS·200) → 2차 GET 캐시 hit.
- **HMR 회귀**: 활성 청크 모듈 edit → HMR `update`; 미활성 청크 모듈 edit → recompile/reload 없음.
- **빌드 게이트**(메모리 `feedback_zig_build_all_targets_before_merge`): `zig build` 전 타깃 + `zig build install`
  후 통합/e2e(스테일 바이너리 방지).

## 8. 범위 밖 (후속)

- parse 까지 지연(최대 cold-start) — RFC #3940 충분 진행 후 별도 단계.
- 프로덕션 빌드 lazy, 활성화용 client→server WS 프로토콜 — MVP 는 청크 GET 자체가 트리거라 불필요.
- NAPI dev 경로(RN, 이미 빠름) lazy 노출 — CLI/web dev MVP 이후.

## 9. 선행 게이트 / GO 조건

- ✅ RFC #3940 rename_table build-scope 이행 완료(§1.2) — GO.
- PR-2(emit 병합) 후 전체 corpus + HMR 통과가 PR-3 진행 게이트.
- kill-switch: `lazy_compilation=false` 가 기존 dev 경로를 100% 보존하는지 매 PR 확인.
