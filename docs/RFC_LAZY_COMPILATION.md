# RFC: Lazy Compilation — dev 서버 온디맨드 청크 컴파일 (A안: parse 지연)

상태: **DRAFT · A안 재설계 · PR-1/PR-2 완료, PR-3+ 재정렬** · 분류: dev UX / bundler
관련: `src/server/dev_server.zig`, `src/bundler/bundler.zig`, `src/bundler/chunk.zig`, `src/bundler/emitter/chunks.zig`, `src/bundler/graph/build_flow.zig`, `src/bundler/incremental.zig`, `src/bundler/linker.zig`, `src/bundler/runtime_helpers.zig`

> **개정 이력**: 본 RFC 의 1차안(MVP)은 "parse eager, transform/codegen/emit 만 지연"이었다.
> 측정(§1.3) 결과 parse 가 dev 빌드의 **81~93%** 를 차지해 MVP 의 cold-start 이득이 ~20% 에 그침이
> 확인됐다. → 본 개정은 **parse 까지 지연(A안)** 으로 모델을 전환한다. PR-1/PR-2(eager dev-splitting
> 토대)는 A안에서도 유효하다(동적 청크를 별도 파일로 emit 하는 기반).

## 1. 배경

ZNTC dev 서버는 시작 시 전체 모듈 그래프를 parse → transform → codegen → emit 하고
(`dev_server.zig` `watchLoop` → `inc_bundler.rebuild()`), `/bundle.js` 요청마다
전체를 다시 번들한다. 라우트 기반 code splitting 앱에서도 **진입조차 안 한 route 의 코드를 시작 시
전부 컴파일**하므로 cold-start 가 느리다 (실측 CLI dev lodash 307~398ms — RFC #3931 측정).

webpack `experiments.lazyCompilation` / rspack lazy compilation 처럼 **브라우저가 실제로 요청하는
청크만 온디맨드로 컴파일**해 dev cold-start 를 줄이는 것이 목표다.

### 1.1 emit 분기 — dev+splitting 은 PR-2 로 성립

과거 `bundler.zig` `bundle()` 의 emit 분기는 dev(단일번들)와 splitting(per-chunk)이 **상호배타**였다.
**PR-2(#4040)** 가 `dev_mode AND code_splitting AND lazy_compilation` 경로(`bundler.zig:1601`
`dev_split`)를 추가해 dev 에서도 per-chunk emit(`emitChunks`)이 동작한다. dev init lowering
(`__zntc_modules[dev_id]`)은 청크 경계를 못 넘으므로(issue #4038) splitting 시 프로덕션 init 으로
fallback 한다. kill-switch: `lazy_compilation=false` 면 기존 dev 단일번들 100% 보존.

**PR-2 까지는 여전히 eager** 다 — 전체 그래프를 parse/transform 한 뒤 청크로 나눠 emit 할 뿐, 시작
비용은 안 줄었다. A안은 이 토대 위에 **parse 자체를 지연**한다.

### 1.2 선행 게이트 — RFC #3940 은 GREEN

청크를 나중에 컴파일하려면 심볼 rename 이 graph 에 박혀 있으면 안 된다(stale). RFC #3940
Sub-PR-L.5c 에서 `Symbol.canonical_name` field 가 **제거**되고 rename 이 **build-scope 단일 store**
(`linker.zig:175` `rename_table: RenameTable`)로 이행 완료됐다. `getCanonicalName` 이 `rename_table`
만 조회(`linker.zig:1400` `lookupSymbolCanonical`). → **lazy 의 심볼-안정성 토대가 이미 깔려 있음.**

> **Zig 초보 메모**: `rename_table` 은 `AutoHashMapUnmanaged(SymbolID, []const u8)` 로, "어떤 모듈의
> 어떤 심볼 → 최종 출력 이름" 매핑이다. 과거엔 이 이름을 각 `Symbol` 구조체 필드에 직접 박았는데
> (`canonical_name`), 그러면 그 `Symbol` 을 만든 빌드가 끝나면 이름 메모리가 해제돼 다음 빌드에서
> stale(이미 해제된 메모리 참조)이 됐다. 이제는 별도 테이블이 소유하므로, 그 테이블만 살려두면
> 나중 빌드에서도 안전하게 읽을 수 있다 — A안이 동적 청크를 나중에 컴파일할 수 있는 핵심 근거.

`rename_table` 은 Linker 소유(build-scope deinit)이므로, **lazy dev 는 Linker(+graph)를 세션 동안
살려둬야** 온디맨드 emit 이 상위 청크 rename 을 읽는다 — `IncrementalBundler`(`incremental.zig`)가
graph 를 빌드 간 유지하는 패턴을 그대로 따른다.

RFC #3933(graph persistence)은 NO-GO 였다. A안은 그 PoC 의 stale-pointer 경로를 쓰지 않고,
**미파싱 모듈은 애초에 그래프에 없다가(placeholder seed) 첫 GET 시 새로 parse** 하는 방식이라
stale 문제 자체가 발생하지 않는다(§4).

### 1.3 측정 — 왜 parse 지연(A안)인가

`--profile=all` (Release/ReleaseFast 빌드, `src/profile.zig`) 로 dev 빌드 파이프라인을 분해한 결과
(7-run median, minify-off = dev-like):

| 케이스 | 모듈 | parse total | 나머지(transform+link+codegen+emit) | **parse 비중** | wall |
|---|---|---|---|---|---|
| lodash-es 부분 import | 641 | 37.7ms | 3.7ms | **91.1%** | 13.6ms |
| date-fns 부분 import | 305 | 27.1ms | 1.9ms | **93.4%** | 10.3ms |
| route-split (lodash+date-fns+d3 동적) | 1511 | 144.9ms | 32.6ms | **81.6%** | 97.8ms |

**parse 가 dev 빌드의 81~93%** 다. 메모리 추정치(~70%)를 Release 측정이 확증(상회)했다.

route-split 앱에서 동적 import 를 제거한 baseline(entry 청크만):

| 케이스 | 모듈 | 청크 | wall |
|---|---|---|---|
| route-split 전체 (eager) | 1511 | 4 (entry + 동적 3) | **97.81ms** |
| entry 청크만 (동적 import 제거) | 1 | 1 | **0.46ms** |

→ **A안의 win = 진입 안 한 route 의 parse+transform+codegen+emit 전체를 cold-start 에서 제거.**
위 극단(entry 가 거의 빈) 케이스에서 97.81ms → 0.46ms. 현실 앱은 entry 셸이 있어 win 은 더 작지만,
**"진입 안 한 route 비중"에 비례**한다.

**MVP(parse eager)가 약한 이유**: parse 가 81~93% 인데 그걸 eager 로 두면, emit 만 지연해 봐야
나머지 7~19% 의 일부만 절약한다. A안은 parse 를 포함한 lazy 청크의 **100% 파이프라인**을 지연한다.

**dev server cold-start 실측 (서버 spawn ~ `/bundle.js` 첫 응답, 6-run median):** 위 빌드 비중은
서버 오버헤드를 뺀 값이라, 실제 dev cold-start 로 검증했다.

| 앱 | eager | entry-only(=lazy 근사) | lazy 절약 |
|---|---|---|---|
| 극단(entry 빈, 1511모듈) | 128ms | 12ms | 91% |
| **현실 SPA**(react 셸 + lazy route 3) | 118ms | 54ms | **54%** |

ZNTC 는 **native dev server 라 서버 오버헤드가 12ms 뿐** → 빌드(parse)가 cold-start 를 지배 →
lazy(빌드 스킵)가 직접 절약한다. **대조 — Rspack 2.0 dev cold-start 는 169ms 인데 그 중 서버
오버헤드(Node 부팅 + serve)가 ~150ms 지배라 lazy on/off 차이가 없다(169 vs 171ms).** 즉 동일한
lazy 전략이라도 **ZNTC(가벼운 native 서버) 에선 빌드가 노출돼 효과가 크고, Rspack(무거운 서버)
에선 묻힌다** — A안이 ZNTC dev 에 특히 유효한 이유다.

> 한계: entry-only 는 "route 0" 근사다. 실제 첫 진입 route 1개는 빌드되므로 절약은 진입 안 한
> route 수에 비례(많을수록 ↑). dev mode(react dev 셸 포함) 실측. 빌드 엔진 자체는 Rspack 2.0 과
> 대등(단일 동등, splitting 은 ZNTC 가 빠르나 splitting 번들 mangle 누락 #4045 로 크기 열위).

## 2. 제안 — "청크 = 첫 GET 시 parse+compile" 모델 (A안)

ZNTC dev 서버는 **모든 청크 URL 라우트를 직접 제어**한다. webpack 식 proxy 모듈·별도 활성화 채널 없이
**dev 서버 라우트 핸들러 자체가 lazy 백엔드**가 된다.

1. **시작 시 (cheap)**: **entry point 모듈만** parse 한다. 그래프 BFS 가 동적 `import()` 경계에 닿으면
   **멈추고**, 타겟 모듈을 "미파싱 청크 seed"로 기록(parse 안 함). entry 청크만 transform→codegen→emit.
   - entry 청크 코드 안의 동적 import 는 `__zntc_load_chunk("<경로기반 안정이름>.js")` 로 lowering.
     타겟 경로만 알면 이름이 결정되므로 청크를 아직 안 만들었어도 참조 가능.
2. **동적 청크 첫 GET 시 (온디맨드)**: 그 seed 경로부터 BFS parse → 청크 모듈집합 transform → codegen
   → emit → 캐시 → 응답. 이 과정에서 또 다른 `import()` 를 만나면 **새 seed 등록**(재귀적 lazy).
   - 트리거: 런타임 `__zntc_load_chunk("...")`(`runtime_helpers.zig:232`)의 `<script>` GET. 기존
     동적 import 런타임 그대로 재사용 → **클라이언트 변경 없음**.
3. **watch/HMR**: 변경 파일이 **이미 활성화된** 청크 소속이면 그 청크만 재컴파일 후 HMR push;
   **미활성** 청크 소속이면 캐시 invalidate 만(parse·컴파일 안 함).

### 2.1 cross-chunk 심볼 모델 — "전역 1회 확정" → "단방향 조회"

MVP(parse eager)는 "시작 시 전체 그래프를 알므로 cross-chunk 심볼 계약을 **전역 1회 확정**"으로
안정성을 보장했다. **A안은 동적 청크를 parse 조차 안 하므로 이 전제가 깨진다** — 시작 시점엔 동적 청크가
무슨 심볼을 import 하는지 모른다. 따라서 모델을 전환한다:

> **entry/shared 청크만 시작 시 rename 확정, 동적 청크는 자기 빌드 시점에 상위 rename 을 조회.**

이게 성립하는 근거:

- **cross-chunk 참조는 단방향(동적 → entry/shared)만 존재.** entry 가 동적 청크 심볼을 정적으로
  참조하는 일은 없다 — `import()` 는 `Promise` 를 반환하는 런타임 경계라 정적 심볼 바인딩이 없다.
- **entry/shared 는 시작 시 parse → `rename_table` 확정.** 동적 청크 빌드 시 그 상위 심볼 이름을
  살아있는 `rename_table`(세션 Linker)에서 조회한다.
- **dev 는 tree-shaking off**(`bundler.zig` dev 경로). entry/shared export 가 전부 보존되므로,
  동적 청크가 나중에 어떤 export 를 참조할지 시작 시 몰라도 안전하다(없어서 깨질 export 가 없음).
- **청크 이름은 모듈경로 기반(안정)** — content-hash 아님. 현재 prod splitting 은 content-hash 이름
  (`split-full.js` 가 `__zntc_load_chunk("lodash-c897bb73.js")` 를 박음). A안 dev 는 동적 청크를 아직
  안 만든 시점에 이름을 박아야 하므로, **타겟 모듈 경로로부터 결정되는 안정 이름**을 쓴다(컴파일 순서
  무관). 이로써 entry 가 동적 청크 이름을 미리 알 수 있다.

핵심: 시작 시 **비싼 per-module 작업(parse 포함)을 entry 청크로 한정**하고, 동적 청크는 단방향으로만
상위를 참조하므로 "나중에 컴파일"이 구조적으로 안전하다.

## 3. 결정된 범위 (A안)

- **경계**: entry point + 동적 `import()` **둘 다** lazy (webpack `entries:true, imports:true` 동치).
- **지연 깊이**: **parse 까지 지연.** 동적 import 경계 너머 모듈은 첫 GET 전까지 parse·transform·
  codegen·emit 어느 것도 안 함. (MVP 의 "transform/emit 만 지연"에서 전환 — §1.3 측정 근거.)
- **적용 면**: **dev 서버 전용** (`zntc <entry> --serve` / JS `startDevServer`). 프로덕션 빌드 불변.
- **shared 청크**: dev lazy 에서는 **shared splitting off**(§6.3). 각 동적 청크가 "entry 에 없는 자기
  의존성"을 인라인(중복 허용). entry 의존성은 단방향 조회. → 점진 parse 와 양립.

## 4. 재사용 인프라 + 신규로 필요한 것

**재사용:**
- 동적 import = 청크 경계: `chunk.zig:585` `addDynamicEntry`. 이미 동작(PR-2).
- 임의 모듈집합 per-chunk rename: `linker.zig` `computeRenamesForModules` + `emitter/chunks.zig`.
- cross-chunk 심볼 배선: `bundler.zig` `computeCrossChunkLinks`.
- 런타임 청크 로더: `runtime_helpers.zig:232` `__zntc_load_chunk` + `__zntc_register`/`__zntc_require`.
- 세션 graph/parse 캐시: `incremental.zig`, `graph/build_flow.zig` `buildIncremental`, `PersistentModuleStore`.
- dev 라우팅/HMR: `dev_server.zig` 라우터, `watchLoop`, WS `/__hmr`.

**신규(A안 핵심):**
- **미파싱 seed placeholder** — `build_flow` 의 BFS discovery 가 동적 `import()` 경계에서 멈추고,
  타겟을 "아직 parse 안 한 청크 seed"로 graph 에 등록하는 인프라. 현재 `addModule` 은 즉시 parse 하므로
  "경로만 등록, 본문 미parse" 상태를 표현할 수 있어야 한다.
  - kill-switch: `lazy_compilation=false` 면 seed 를 즉시 parse(기존 eager 동작) → 회귀 0.
- **온디맨드 parse 백엔드** — dev 서버 라우트가 청크 GET 시 seed 부터 BFS parse → emit. 세션 Linker
  생존(§1.2). `LazyChunkCache`(경로기반 키).

> **Zig 초보 메모**: BFS discovery(`build_flow.zig`)는 entry 부터 import 를 따라가며 "다음에 parse 할
> 모듈" 큐를 넓혀가는 너비우선 탐색이다. 현재는 정적 import 든 동적 import 든 전부 큐에 넣어 끝까지
> parse 한다. A안의 신규 작업은 동적 import 타겟을 **큐에 넣는 대신 seed 목록에 따로 빼두는 것** 뿐이라,
> 탐색 알고리즘 자체는 그대로다.

## 5. 단계별 PR 분할 (A안 재정렬)

- **PR-0 — 측정** ✅(본 RFC §1.3): parse 81~93% 확증, A안 GO.
- **PR-1 #4037** ✅: RFC + `lazy_compilation` 옵션 스캐폴딩.
- **PR-2 #4040** ✅: dev+splitting emit 병합(eager). `dev_split` 경로. #4038 CLOSED. **A안 토대.**
- **PR-3a — 미파싱 seed + 경계 정지**: 구현 surface 가 커서(emit-skip·경로기반 naming 까지
  transitively 필요) **3a-i / 3a-ii 로 분할**(CLAUDE.md "작은 PR").
  - **PR-3a-i (구현 중)**: discovery 경계 정지 + seed materialize 인프라. `resolve_imports` 가
    `lazy_compilation and kind==.dynamic_import` 면 타겟을 `graph.lazy_seeds` 로 deferred(addModule=
    parse 회피), `build_flow.materializeLazySeeds` 가 BFS 종료 후 일괄 등록 — static 도달이면 그
    파싱 모듈에 link, 아니면 미파싱 seed(`Module.is_lazy_seed`, state=.ready, ast=null). 동적 청크는
    seed 본문 없이 emit(stub). **`lazy_compilation=false` = byte-identical 회귀 0**(전 코드경로 게이트).
  - **PR-3a-ii DONE**: 미파싱 seed 청크 emit-skip + **경로기반 안정 청크 이름**(content-hash 는
    청크를 만들어야 계산되므로 미생성 동적 청크 참조와 모순). `Chunk.is_lazy_seed`+`lazy_path_hash`
    (=Wyhash(entry path)), `chunkPlaceholderStem` 이 lazy seed 면 `[hash]`를 경로 hash 로 치환
    (`\x00ZH` placeholder 없음 → resolveContentHashes 무시 → 안정). emit 루프+resolveContentHashes
    공유 predicate(`chunkSkippedFromOutput`)로 skip. entry 는 `heavy-<pathhash>.js` 로 선참조 —
    본문이 바뀌어도 이름 불변(테스트 가드) → PR-3b 가 on-demand 빌드해도 이름 일치.
- **PR-3b — dev 서버 lazy 라우트**: 두 어려운 전제(세션 Linker 생존 + 단일청크 emit)로
  **3b-i / 3b-ii / 3b-iii 로 분할**.
  - **PR-3b-i DONE**: `emitChunks` 가 `EmitOptions.restrict_to_chunk` 로 *단일* 청크만 emit
    (lazy seed 면 force-emit). on-demand 컴파일의 emit 전제. `chunkRestrictSkip` 로 emit
    루프+resolveContentHashes 동일 skip. restrict=null=byte-identical 회귀0. **제약**: lazy
    청크(경로기반 reg_id 참조) 전용 — content-hash cross-ref 청크면 dangling.
  - **PR-3b-ii (진행 중 — 접근 (B) 결정론적 재빌드 검증)**: on-demand 를 (A)세션 Linker 생존
    대신 **(B) 결정론적 재빌드**(요청 seed 만 force-parse + `restrict_to_chunk` 로 단일청크
    emit, Linker 는 매번 fresh)로 가는지 검증. **force-parse primitive** 추가 완료
    (`BundleOptions.lazy_force_parse: []const []const u8` — 지정 절대경로 동적타겟을 lazy
    defer 대신 즉시 parse. resolve_imports gate 에 `!pathInForceParse` 추가). **검증 결과
    (B)는 2겹 선행 필요**:
    1. **shared-splitting-off (§6.3)**: force-parse 시 seed 가 entry 와 공유하는 모듈이 공통
       청크로 추출돼 entry 청크가 달라짐(비결정론). lazy 시 static-entry 비트 보유 모듈의
       dynamic 비트를 collapse 해 entry 에 고정 → 결정론. (chunk.zig generateChunks Phase3 전.)
    2. **entry export-all-by-local**: shared-off 로 shared 가 entry 에 hoist 되면, 동적 청크는
       `__zntc_require("entry.js").<local>` 로 단방향 조회한다. 그런데 cross-chunk export 가
       **demand-driven**(소비자 있을 때만)이라 초기 lazy 빌드(seed 미파싱)는 그 export 를 안
       내 → on-demand seed 가 못 찾음. 해법: **lazy 시 entry 청크가 hoisted 모듈 export 를
       전부 *local(deconflict) name* 으로 노출**(`exports.v=v; exports.v$1=v$1;`). export-name
       으로는 동명 충돌(shared.v + dup.v)이라 local name 필수. 이건 registry emit 신규 경로
       (chunks.zig xchunk_exports 의 reg-entry break 를 lazy export-all 로 대체). **미구현.**
    → 즉 (B)는 viable 하나 `shared-off + export-all-by-local` 선행. PR-3b-ii 잔여 = 이 둘 구현.
  - **PR-3b-iii**: lazy 라우트 — `/<heavy-pathhash>.js` GET 시 seed force-parse→`restrict_to_chunk`
    단일청크 emit→`LazyChunkCache`. 이름→seed 역참조는 `graph.lazy_seeds`. virtual/external 동적
    타겟 lazy 도 여기.
- **PR-4 — watch/HMR + 재귀 lazy**: 활성/미활성 청크 분기. 동적 청크 parse 중 발견한 새 `import()` 를
  seed 로 추가. 그래프 구조 변경 시 entry 청크 재계산.
- **PR-5 — 검증/벤치 + `--lazy` 노출**: cold-start 벤치(§1.3 harness 확장), 로드맵 "미구현" 제거,
  CLI `--lazy`/JS 옵션 공개.

> **메모리 `feedback_default_change_napi_drift`**: PR-5 에서 `--lazy` 를 사용자에게 노출할 때
> `options.zig`/`index.ts`/typo-suggest/`cli-flags.mjs`/`zntc.mjs`/`dto_test` 6곳을 일관 변경.
> 한 곳 누락 시 사용자 옵션이 silent 무시된다.

## 6. 핵심 리스크와 완화

### 6.1 cross-chunk 심볼 안정성 (A안 핵심 난이도)
동적 청크를 나중에 parse·컴파일할 때 상위(entry/shared) export 이름을 정확히 참조해야 한다.
→ §2.1 단방향 모델: entry/shared 는 시작 시 rename 확정 + 세션 Linker 로 `rename_table` 생존 +
dev tree-shake off 로 export 보존. 역방향 정적 참조는 구조적으로 없음(`import()` = Promise).
**가드**: route-split corpus 에서 "동적 청크가 entry 심볼 참조" 케이스의 출력이 eager 빌드와
의미 동치인지(런타임 실행 결과) 검증.

### 6.2 dev 모드 회귀
kill-switch(`lazy_compilation=false`)가 기존 dev 단일번들/eager-splitting 경로를 100% 보존하는지
매 PR 확인. PR-3a 의 seed 도 eager fallback 으로 회귀 0.

### 6.3 shared 청크 / 청크 이름 (신규 결정)
- **shared splitting off (dev lazy)**: 점진 parse 와 shared 청크 분리는 충돌한다 — 동적 청크 A·B 를
  parse 하기 전엔 그들이 공유하는 모듈을 알 수 없다. dev 에서는 shared 를 분리하지 않고 각 동적 청크가
  자기 의존성을 인라인(중복 허용)한다. 코드 중복은 dev cold-start 목표와 무관하고, 메모리
  `project_css_chunk_multi_owner`(CSS 의 도달-모든-청크 복제)의 JS 판이다. **단 entry 청크에 이미 있는
  모듈은 동적 청크가 인라인하지 않고 단방향 조회**(entry 는 시작 시 parse 됨 → 모듈집합 확정).
- **경로기반 안정 청크 이름**: content-hash 는 청크를 만들어야 계산되므로 A안과 모순(entry 가 미생성
  동적 청크 이름을 박아야 함). dev lazy 는 타겟 모듈 경로로부터 결정되는 이름을 쓴다.

### 6.4 Linker 생명주기 / 메모리 소유
`rename_table` 이 Linker 소유 → 세션 동안 graph+Linker 유지. `IncrementalBundler` 패턴 재사용.
> **메모리 `CLAUDE.md` arena 규칙**: 세션 동안 살아있는 graph/Linker 의 arena 리소스에 개별
> `defer X.deinit()` 를 걸지 말 것 — 세션 종료 시 arena 일괄 해제(#1287 segfault 회피).

## 7. 측정 / 검증

- **cold-start 벤치**(§1.3 harness 확장): route-split 샘플에서 `--serve --lazy` vs `--serve` 서버
  기동~첫 응답. 기대: lazy 시작 시 heavy route 미parse(로그), 진입 시 `/<chunk>.js` 첫 GET 에 최초 parse+compile.
  GO 기준: route-split 앱 cold-start 가 entry 청크 parse 시간 수준으로 수렴(진입 안 한 route parse 0).
- **통합 테스트**(`tests/integration` cwd 준수 — 메모리 `feedback_integration_test_cwd`): dev 기동 →
  `GET /bundle.js`(entry 컴파일·200) → 동적 청크 URL 캐시 miss → 그 URL GET(유효 JS·200, 단방향 심볼
  참조 정확) → 2차 GET 캐시 hit.
- **HMR 회귀**: 활성 청크 모듈 edit → HMR `update`; 미활성 청크 모듈 edit → recompile/reload 없음.
- **빌드 게이트**(메모리 `feedback_zig_build_all_targets_before_merge`): `zig build` 전 타깃 +
  `zig build install` 후 통합/e2e(스테일 바이너리 방지 — 본 RFC 측정도 ReleaseFast 재빌드 후 수행).

## 8. 범위 밖 (후속)

- 프로덕션 빌드 lazy(프로덕션은 content-hash·shared splitting·tree-shake 가 핵심이라 단방향 모델 부적합).
- 활성화용 client→server WS 프로토콜 — 청크 GET 자체가 트리거라 불필요.
- NAPI dev 경로(RN, 이미 빠름) lazy 노출 — CLI/web dev MVP 이후.
- shared 청크를 점진적으로 재분리(dev) — 중복 인라인으로 충분, 복잡도 대비 이득 낮음.

## 9. 선행 게이트 / GO 조건

- ✅ RFC #3940 rename_table build-scope 이행 완료(§1.2) — 심볼-안정성 GREEN.
- ✅ PR-0 측정(§1.3): parse 81~93% + **dev cold-start 실측(현실 SPA 118→54ms = 54% 절약, 극단 91%)** → **A안 GO**. ZNTC native 서버(오버헤드 12ms)라 빌드가 cold-start 지배 → lazy 직접 효과. 단 Rspack(무거운 서버)은 lazy 묻힘이라 **A안은 ZNTC native dev 에 특히 유효**(범용 일반화 주의).
- ✅ PR-2(emit 병합) 머지 — dev per-chunk emit 토대.
- PR-3a 의 eager fallback(`lazy_compilation=false`)이 전체 corpus 회귀 0 인지가 PR-3b 진행 게이트.
- kill-switch: `lazy_compilation=false` 가 기존 경로를 100% 보존하는지 매 PR 확인.
