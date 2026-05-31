# RFC: Lazy dev — 요청된 seed 를 watch 그래프에서 materialize (깊은 편집 HMR + warm 재빌드)

상태: **DRAFT · 타당성 검증 완료(force-parse 누적 경로) · 미착수** · 분류: dev UX / bundler / NAPI
관련: `packages/core/src/napi/watch.zig`, `packages/core/bin/zntc.mjs`, `packages/core/index.ts`, `src/bundler/graph/resolve_imports.zig`, `src/bundler/emitter/chunks.zig`, `src/bundler/chunk.zig`, `src/bundler/bundler.zig`
선행: `RFC_LAZY_COMPILATION.md`(A안 완결, #4053~4080) · 이슈 #4079

## 1. 배경 — 무엇이 남았나

`zntc dev --lazy` (RFC_LAZY_COMPILATION A안, #4053~4080 완결) 는 동적 `import()` 타겟을
미파싱 seed 로 두고 브라우저 요청 시 on-demand 로 컴파일한다. 그러나 두 한계가 남았다:

1. **#4079 — 깊은 편집 HMR 미동작 (체감 큼).** lazy seed 는 watch 그래프에 미파싱 stub
   (`is_lazy_seed=true, ast=null`, `build_flow.zig:206-208`)으로만 들어간다. 파싱이 안 되니 그
   seed 가 정적 import 하는 *하위 파일들*(라우트의 실제 컴포넌트/유틸)이 그래프에 없고, watch
   tracked set(=`module_paths`, `watch.zig:1499-1518`)에도 없어 **감시되지 않는다**. 그 하위
   파일을 편집하면 fs 이벤트조차 안 잡혀 rebuild 가 안 일어난다 → 화면 안 바뀜. 라우트 진입
   파일(seed) 자체는 stub 으로 그래프에 있어 감시되지만, 그 *안쪽*은 사각지대.

2. **seed 본인 편집 ~수초.** seed 를 편집하면 on-demand `build()`(zntc.mjs)가 도는데, 이건
   `module_store`/`compiled_cache` 가 NAPI `build()` 경계를 못 넘는 **별개 cold 빌드**라 entry
   그래프 전체를 재파싱한다.

근본 원인은 **dual-graph**: watch worker 의 그래프(seed=stub)와 실제 서빙되는 청크를 만드는
on-demand `build()`(seed=parsed) 가 *서로 다른 그래프*다. watch 그래프는 "실제로 서빙되는 것"의
진실을 모른다. 그래서 seed 하위를 감시도 못 하고, 서빙도 cold 별개 빌드로 한다.

## 2. 목표 — 단일 그래프 (webpack lazyCompilation 모델)

**요청된 seed 를 watch worker 가 *자기 그래프에서* 정식 컴파일**하게 한다. 그러면:

- seed 의 subtree 가 watch 그래프 → `module_paths` → tracked set 에 자연히 들어가 **자동 감시**
  → 깊은 편집이 rebuild 를 일으킨다 (**#4079 해결**).
- seed 가 warm watch 그래프의 정식 모듈이 되어 증분 rebuild 가 `compiled_cache`/`module_store`
  를 재사용 → cold 별개 빌드 제거 (**~수초 해결**).
- 별개 `build()` / dual-graph / epoch 가드 / "store 가 NAPI 경계 못 넘음" 부속 기계가 사라진다
  (정밀 캐시 무효화 #4080 은 그대로 유효·더 잘 맞물림).

**모델**: "방문 전엔 lazy(미컴파일), *방문하면* 그 뒤로 정식 모듈처럼 컴파일·감시" — webpack
`experiments.lazyCompilation` 과 동일. cold-start 가치(미방문 라우트 미컴파일)는 100% 유지.

## 3. 핵심 결정 — live 그래프 변형이 아니라 "force-parse 누적 + fresh rebuild"

§2 를 순진하게 읽으면 "watch 의 영속 그래프를 세션 중에 stub→parsed 로 mutate" 인데, 그건
`RFC_GRAPH_PERSISTENCE.md`(#3933) 를 **stale canonical_name ptr segfault 로 CLOSE 시킨 위험
지대**다. **본 RFC 는 그 경로를 택하지 않는다.**

대신 검증된 안전 경로:

> **watch 는 이미 fresh-per-build 다.** 매 rebuild 가 새 `Bundler`+새 `ModuleGraph` 를 만들고
> (`watch.zig:1240`), 보존되는 건 graph 객체가 아니라 `module_store`(파싱 AST 캐시) /
> `persistent_resolve_cache` / `compiled_cache` 뿐이다 (`incremental.zig:245-250` 가 "매 빌드
> graph fresh init, 이전 graph deinit" 명문화). 따라서 **요청된 seed 경로를 `lazy_force_parse`
> 집합에 누적하고 매 rebuild 가 그 집합으로 fresh 빌드**하면, force-parse 된 seed 는 정식 파싱돼
> subtree 가 그래프에 들어오지만(`resolve_imports.zig:380` 의 `!pathInForceParse` 게이트 우회)
> **그래프 노드 포인터는 매 빌드 새로 만들어진다** → stale-ptr 위험 0.

→ **방향 2 는 RFC #3940(lifecycle scope redesign) 에 의존하지 않는다.** (당초 의존 추정은 "live
변형" 프레이밍의 오판이었고, fresh-per-build 확인으로 해소.)

`lazy_force_parse` 는 이미 watch 옵션 경로를 탄다(`options.zig:331`→worker `bundle_opts`
→`incremental_opts`→`bundler.zig:1195` graph 전파, miss/replay 양쪽 게이트). 메커니즘은 코드상
이미 성립 — 남은 건 *런타임에 그 집합을 키우는* 표면과 *청크 이름 안정성*이다.

## 4. 작업 항목 (PR 시퀀스)

### PR-1 (emitter): (이전) lazy seed 청크는 force-parse 후에도 path-hash 안정 이름 유지

**문제(설계 함정):** lazy seed(미파싱) 청크 이름 = `<stem>-<lazy_path_hash>.js`(경로 기반,
`chunk.zig:813-815`). force-parse 되면 `is_lazy_seed=false` → content-hash 이름으로 바뀐다
(`chunks.zig:2027-2030`). 그러면 브라우저가 박아둔 `__zntc_load_chunk("page-<pathHash>.js")` URL
과 새 파일명이 어긋난다(seed 가 entry 청크에 인라인될 위험도). 한 빌드 *내부*는 정합하나(재작성과
파일명이 같은 `chunkPlaceholderStem` 호출), 빌드 *전환*(lazy→force-parse) 시 외부 URL 이 깨진다.

**해결:** "동적 import 타겟(=former lazy seed)" 인 청크는 force-parse 여부와 무관하게 **항상
`lazy_path_hash` 이름**을 쓴다(`graph.lazy_seeds` 또는 dynamic-import-target 표식 기준). + 그
모듈은 별도 청크로 유지(entry 인라인 금지). → 외부 URL 불변 → dev 서버 매핑 변경 0.

테스트: `build({lazyForceParse:[seed]})` 결과 청크 이름이 lazy 빌드의 `__zntc_load_chunk` 참조
해시와 동일(napi-lazy-primitives). byte-identical 회귀 가드(non-lazy/non-force 0 영향).

### PR-2 (NAPI): `WatchHandle.requestLazySeed(path)` + worker mutable force-parse set + wakeup

- `index.ts WatchHandle` + watch.zig handle 에 `requestLazySeed(path)` 추가(현 3 메서드뿐,
  `watch.zig:1835`).
- `async_data` 에 mutex-protected `lazy_force_parse` 누적 set(owned-copy — slice 는 borrow,
  `bundler.zig:155`) + worker loop 깨우기 채널(현재 `tracked.waitForChanges` 만 block,
  `watch.zig:1119` — 별도 wakeup 필요).
- 매 rebuild 가 `incremental_opts.lazy_force_parse = 누적_set` 을 읽도록 wire.
- 중복/순서 무해(이미 force-parse 면 no-op). 같은 seed 재요청 dedup.

### PR-3 (JS dev 서버): hybrid — 첫 요청 즉시 서빙 + 백그라운드 force-parse 누적

- `tryServeLazy` 가 seed URL 을 처음 받으면: (a) 기존 on-demand `build()` 로 **즉시 1회 서빙**
  (현 경로 재사용, zntc.mjs:2182), (b) `handle.requestLazySeed(seedPath)` 호출 → 다음
  rebuild 부터 watch 그래프가 그 seed 를 정식 포함·감시.
- 이후 그 청크는 watch 가 outdir 에 emit(정식 청크) → 정적 `handleRequest` 로 서빙. PR-1 의
  path-hash 안정 이름 덕에 URL 불변.
- 정밀 캐시 무효화(#4080)·seed 맵은 그대로 — force-parse 후엔 event.changed 에 subtree 가
  잡혀 정밀 무효화가 자동 동작.

### PR-4 (정리, 선택): on-demand 별개 build() 경로 축소 + epoch 가드 제거 검토

force-parse 누적이 안정화되면 첫-요청 즉시 서빙만 별개 build() 로 남기고, 그 외 경로(캐시·epoch
가드)는 watch 정적 서빙으로 흡수 가능한지 검토.

## 5. 무엇이 해결되나

| 한계 | 해결 |
|------|------|
| #4079 깊은 편집 HMR | ✅ subtree 가 그래프→감시 → 편집 시 rebuild + 정밀 무효화 |
| seed 편집 ~수초 | ✅ warm watch 그래프 재사용(별개 cold build 제거) |
| dual-graph 복잡성 | ✅ 단일 그래프 — epoch 가드/별개 build/NAPI store 우회 제거(PR-4) |
| 동적 import 제거 시 청크 정리 | ✅ 모듈이 그래프에서 빠지면 unwatch·재emit 안 됨 |

## 6. 리스크 / 오픈 퀘스천

- **PR-1 청크 이름**: "dynamic-import-target 청크" 식별을 `graph.lazy_seeds` 로 할지, 모듈 플래그
  (`is_dynamic_import_target`)를 신설할지. force-parse 시 인라인 방지 게이트 위치(generateChunks
  Phase3). byte-identical 가드 필수.
- **PR-2 wakeup**: worker loop 의 `waitForChanges` 와 별개로 request 를 깨우는 채널 설계(파이프/
  condvar). teardown(#4063/#4066) 과의 상호작용 재확인.
- **누적 set 무한 성장**: 세션이 길고 라우트가 많으면 force-parse set 이 계속 큰다(= 점점 eager).
  이는 의도된 동작(방문한 라우트는 컴파일 유지)이나, "오래 안 쓴 seed 를 다시 lazy 로 강등"하는
  LRU 는 범위 밖(후속).
- **첫 요청 hybrid**: 즉시 on-demand 서빙과 force-parse rebuild 완료 사이 race — 정밀 무효화/
  epoch 가드가 이미 그 window 를 커버하는지 재검증.

## 7. 비목표

- live 영속 그래프 변형(RFC #3933 경로) — 명시적으로 안 함.
- production 빌드 동작 변경 — `--lazy` dev 전용. force-parse 청크 이름 변경(PR-1)도 lazy 빌드
  한정 게이트.
- `restrict_to_chunk` NAPI 노출 — 현재 EmitOptions 전용(`emitter.zig:91`), 본 RFC 미사용(첫
  요청은 기존 on-demand build() 재사용).
