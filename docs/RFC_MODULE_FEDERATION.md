# RFC: Module Federation & 분할 배포 (웹 + React Native)

> 상태: **Draft (브레인스토밍 결론 정리)**
> 범위: 웹/RN Module Federation, 청크 분할 배포, 자체 C/JSI 네이티브 로더
> 결정 모드: 아래 "확정된 결정"은 논의를 거쳐 고정됨. "미해결"은 추가 논의 필요.

---

## 1. 배경 & 목표

"수정한 부분만 배포"라는 요구는 두 가지로 갈리며, 해법이 완전히 다르다.

- **A) 엔드유저가 바뀐 코드만 다시 받는다** — content-hash 청크 분할 + immutable 캐시로 해결. zntc는 이미 거의 지원(아래 §6). 상태 공유 문제 없음.
- **B) 팀이 독립적으로, 전체 앱 재빌드 없이 배포한다** — 진짜 Module Federation(MF). 상태 공유 세금이 발생.

→ **본 RFC의 목표는 B다.** (논의에서 B로 확정)

MF는 마이크로프론트엔드 = 마이크로서비스의 프론트판이다. 각 팀이 자기 도메인 상태를 소유하고, 독립 빌드된 번들끼리 **런타임에** 결합한다.

---

## 2. 확정된 결정

| # | 결정 | 근거 |
|---|---|---|
| D1 | **하이브리드: 자체 최적화 코어 + MF 2.0 호환 경계** | 코어 성능(호이스팅 보존)을 살리면서 기존 MF 생태계(host/devtools/`@module-federation/*`)와 interop |
| D2 | **shared 버전 = 빌드타임 핀 기본**, 런타임 협상은 웹 전용 opt-in | 다수(모노레포·단일팀·RN)에 DX 우위. RN은 네이티브 ABI 때문에 핀이 물리적으로 강제 |
| D3 | **빌드타임 계약 검증을 1급 기능으로** | MF 2.0의 stale `.d.ts` 다운로드 대비 핵심 차별화. CI 호환성 매트릭스를 빌드타임으로 shift-left |
| D4 | **RN 네이티브 로더를 자체 구현 (C/Zig 코어 + JSI + thin shim)** | Re.Pack 의존 없이 zntc가 RN MF를 온전히 소유. zntc의 Zig/C 강점에 정합 |
| D5 | **RN은 TurboModule / New Architecture 전용** | Old Arch bridge 래퍼 제거 → 스코프 축소, 분기 최소화 |
| D6 | **웹 MF 먼저 → RN 나중** | 웹은 스택 전체를 zntc가 소유 → 차별화 온전. RN은 별도 난이도 |

### 결정의 핵심 통찰

- **"수정 부분만 배포"의 전제는 상태/서버호출 소유권의 도메인별 분산**이다. 그게 안 된 코드베이스에선 host가 계속 배포 나가 MF 의미가 없다.
- **라이브러리 싱글톤 ≠ store 인스턴스 싱글톤.** node_modules dedup은 쉽지만 store 인스턴스는 앱 코드에 산다. 별도 메커니즘(앱 소유 모듈의 shared scope 싱글톤 등록)이 필요하다.
- **RN MF의 네이티브 로딩은 순수 JS로 불가능**하다(§5). `<script>`·URL `import()` 없음, Hermes는 문자열 `eval` 차단. 네이티브 로더가 *전제*다.

---

## 3. 상태 관리 설계 (B의 핵심 세금)

### 3.1 재설계 방향: "인스턴스는 단일, 소유권은 분할"

- ❌ 거대한 전역 트리에 모두가 손 뻗는 monolithic store → 팀 간 결합 → 독립 배포 불가
- ✅ **단일 store 인스턴스 + 네임스페이스 slice 소유권**: 각 remote는 자기 slice만 소유·수정. 남의 slice는 *공개 selector/action 계약*으로만 접근(raw shape 직접 접근 금지)
- cross-cutting 전역(auth/user/theme/i18n) = **host 소유 canonical slice**, remote는 read + 공개 action만
- ephemeral UI 상태(폼/모달) = store에 안 올리고 remote-local

### 3.2 권장 패턴: host 단일 store + 동적 slice 주입

- host가 단일 store + Provider 소유. store-보유 모듈은 eager 싱글톤으로 강제
- remote는 로드 시점에 자기 slice/reducer/atom을 host store에 주입(Redux dynamic reducer injection / Zustand slice / Jotai)
- remote가 자체 store/Provider 생성 시 zntc 빌드 경고 (소유권 경계 린트)

### 3.3 서버 상태 안티패턴

"API 호출을 전부 host Redux에 담는" 설계는 MF와 정면충돌한다(엔드포인트 변경마다 host 배포).

- 서버 상태는 공유 전역 상태가 아니라 **캐시**다. 엔드포인트 정의를 각 remote가 소유
- 공유하는 건 캐시 인프라지 엔드포인트가 아니다: **RTK Query `apiSlice` 인스턴스 1개를 shared 싱글톤, 엔드포인트는 remote가 `injectEndpoints`로 주입** / React Query `QueryClient` 싱글톤 + query 정의는 remote 소유

### 3.4 계약 버전 관리

- 버전 축 3개를 분리: ① shared 라이브러리(host canonical, build-time 핀) ② **store 계약**(`@app/store-contract@x.y.z` 별도 패키지, host·remote 둘 다 빌드) ③ remote 자체 버전(매니페스트 + immutable URL)
- 원칙: **계약은 명시적 버전, 구현은 자유**
- 진화는 **expand-then-contract만**: ① 새 필드 추가(양쪽 호환) → ② 모든 remote 이전 → ③ 옛 필드 제거 → major break ≈ 0

### 3.5 전체/협응 배포가 강제되는 시점 (host 배포 트리거)

일상(구현 변경, additive 계약, 자기 slice)은 remote만 배포. 협응 배포가 강제되는 건:

1. shared 싱글톤 메이저 업그레이드(react/react-native) — 본질적으로 못 피함
2. store 계약 breaking(major) — expand-contract로 빈도 최소화
3. 셸 자체 변경(라우팅/레이아웃/remote 등록/부트스트랩) — 단방향(remote 무영향)
4. federation 런타임/프로토콜 ABI 변경 — **zntc 책임**, lockstep 릴리스와 직결
5. (RN 전용) 네이티브 의존성 변경 / Hermes bytecode 버전 업 / 코드서명 키 로테이션 — 앱스토어 릴리스 트레인

→ 좋은 설계의 목표 = 1을 제외한 2~5의 *빈도 최소화*.

---

## 4. 아키텍처 (공통 + 웹)

### 4.1 공통 빌딩블록

- **연합 경계 한정 안정 모듈 ID**: 내부 청크는 스코프 호이스팅 유지(ID 소거), remote/shared 경계 모듈에만 결정적 안정 ID 부여. 독립 빌드 간 ID 결정성이 매니페스트 신뢰성의 근간
- **MF 2.0 호환 런타임**: container(`get`/`init`), shared scope. 자체 코어가 만든 출력을 `@module-federation/runtime` 계약에 맞춰 emit (벤더가 아니라 스펙 타겟 → 락인 완화)
- **서명된 매니페스트**: `remoteName → immutable URL`, 청크별 content hash + 서명. 배포 = 포인터 교체(롤백 = 이전 immutable URL)
- **빌드타임 계약 검증**(D3): remote는 게시된 계약 버전에 빌드, host는 등록된 remote 호환성을 빌드/배포 시 검증 + 런타임 가드 폴백

### 4.2 웹 MF (Phase 1~2, 먼저)

- 청크 분할/`public_path`/동적 import 재작성은 이미 존재(§6) → container + shared scope + `mf-manifest.json` 에미터 + `remoteEntry` 출력 추가
- 로더는 ESM 네이티브 `import()` 또는 경량 script 주입
- 검증: `@module-federation/enhanced` host와 interop 확인

---

## 5. RN MF 아키텍처 (자체 C/JSI 로더)

### 5.1 왜 네이티브 로더가 전제인가

stock RN/Metro: `import()`는 네트워크 청크를 안 만들고 단일 번들에 인라인. RN엔 `<script>`·URL `import()` 없음, Hermes는 문자열 `eval` 차단. → "청크 분할 → 네트워크 다운 → 실행"은 **로더 교체로만 가능**하며 그 일부는 *반드시 네이티브*다.

### 5.2 설계 척추: 네이티브는 최소, 페더레이션 로직은 JS

| 레이어 | 언어 | 책임 | 안정성 |
|---|---|---|---|
| **Zig/C 코어** (`zntc-rn-loader-core`) | Zig | 매니페스트 파싱, 캐시 인덱스/축출, 해시 계산, RS256 JWT 서명 검증, 오프라인 결정, 상태머신(resolve→캐시확인→fetch/serve→verify→evaluate) | iOS/Android 동일 바이너리 재사용 |
| **JSI 바인딩** | C++ | `__zntc_loadScript` 노출, JS resolver 콜백 ↔ 코어 마샬링, 버퍼를 런타임에 전달 | 얇음 |
| **플랫폼 shim** | Obj-C++ / Kotlin | HTTP(NSURLSession/OkHttp), 앱 샌드박스 경로, **TurboModule codegen 등록(New Arch only)** | 최소 표면 |
| **JS (zntc emit + MF2 런타임)** | JS | container, shared scope, 버전 핀, 계약 검증, resolver 정책 | zntc가 빠르게 iterate |

**원칙: 네이티브에 페더레이션 로직 0.** 네이티브 책임은 `resolve→fetch→verify→cache→evaluate`까지. container/shared scope/계약은 전부 JS. 이 경계가 네이티브 표면을 작게 유지 → 유지보수 늪 최소화.

> **Zig 초보 설명**: "코어를 Zig로, 경계만 C++/네이티브"인 이유 — Zig는 C ABI로 정적 라이브러리를 만들 수 있고(`build.zig`의 static lib), iOS/Android 양쪽에서 같은 `.a`를 링크해 로직 중복을 없앤다. C++(JSI)·Obj-C·Kotlin는 "JS 엔진/플랫폼 API에 닿는 얇은 껍데기"만 담당한다. 이미 `packages/core/src/napi/common.zig`가 Zig↔C(NAPI) interop을 같은 방식으로 한다 — 그 패턴을 JSI(C++)로 옮기는 것.

### 5.3 엔진에 먹이는 경로 (가장 민감 → 설계로 완화)

- JSI의 `Runtime::evaluateJavaScript(Buffer, url)`는 비교적 안정적 표면. **Hermes는 Buffer가 소스든 .hbc 바이트코드든 magic으로 자동 판별** → 소스/바이트코드 둘 다 *표준 JSI 표면 하나*로 처리, Hermes 준-비공개 내부 API 회피
- New Arch 전용(D5)이므로 Old Arch bridge 분기 없음 → TurboModule(JSI install) 한 경로만
- 진짜 fragile한 부분은 "downloaded Buffer를 살아있는 RN Hermes 런타임에 evaluate해서 federated 모듈이 등록·렌더되나" — 이걸 스파이크 0(§8)에서 먼저 증명

### 5.4 보안 모델 (다운로드 / 저장 / 검증)

원격 코드 실행은 `eval` 키워드 문제가 아니라 *런타임 원격 코드 실행* 자체가 위험(웹 포함 동일). 관리:

- **다운로드**: 네이티브 측(NSURLSession/OkHttp), HTTPS + cert 피닝, locator에 인증 헤더
- **저장**: 앱 샌드박스 파일시스템(iOS Caches/Android filesDir), scriptId+해시 키, 오프라인 시 마지막 good 캐시 서빙
- **검증(실행 *전*, 네이티브에서)**: 빌드타임에 청크/.hbc content hash → RS256 JWT 서명(개인키는 CI 시크릿). 앱 바이너리에 공개키 임베드. 런타임에 JWT 서명 검증 + 본문 해시 대조, 통과 시에만 엔진 전달, 실패 시 거부+fail-soft
- 신뢰 루트 = 바이너리에 박힌 공개키 → **키 로테이션 = 앱스토어 릴리스**(§3.5-5). 서명은 무결성·진위성만 보장(기밀성 X) → 청크에 시크릿 금지. MF 위협 모델은 remote = 1st-party 전제

### 5.5 사용자(앱 개발자)가 지는 것

네이티브 다운로드/저장/검증 코드는 **zntc 패키지가 제공**(install + autolink). 앱 개발자가 ObjC/Kotlin 작성 안 함. 사용자 소유는: 작은 JS resolver(어디서·어느 버전·인증), 키 관리(키쌍 생성·공개키 임베드·개인키 CI), CDN/매니페스트 인프라, 선언적 MF config. zntc는 기본 resolver/스캐폴드를 생성해 사용자 글루를 "baseURL + 키" 수준까지 축소.

**1회성 비용**: zntc RN federation 패키지 도입 = 네이티브 추가 → 앱 바이너리 재빌드(= host 릴리스 이벤트, §3.5와 일관).

---

## 6. 코드베이스 실측 (구현가능성)

> 근거는 실제 코드. 추측 아님.

### 6.1 번들러 측

| 항목 | 현황 | 결론 |
|---|---|---|
| 청크 content hash | ✅ Wyhash 기반 2-pass placeholder 치환, 결정적 — `src/bundler/emitter/chunks.zig:1281-1339` | **재사용**(파일명용). 단 Wyhash는 비암호화 → 무결성/서명엔 부적합 |
| public_path 주입 | ✅ `src/bundler/emitter/chunks.zig:1029-1035` | **재사용** (remote 청크 URL 주입) |
| cross-chunk import 생성 | ✅ `src/bundler/emitter/chunks.zig:230-301` (심볼 기반 + deconfliction) | **재사용** |
| metafile JSON | ✅ `src/bundler/bundler.zig:1612-1677` (esbuild 호환, bytes만) | **확장**: `OutputFile.content_hash` 필드 + 청크→모듈 매핑. 침습성 낮음(시그니처 변경 불필요, `multi_outputs` 이미 존재) |
| 모듈 안정 런타임 ID | ⚙️ **P3-B PR1 에서 하위 인프라 구현됨** — `src/bundler/module_id.zig`(relative-path 스킴 확정, RFC_CJS §4.4/§7). 스코프 호이스팅 소거는 여전 → 경계 모듈에만 적용 | **재사용**: P1 은 이 `module_id.zig` 를 그대로 씀(중복 구현 금지) |
| module registry / container 런타임 | ✅ **P3-B 에서 단일 canonical 레지스트리 코어 구현됨(P3-C 수렴 완료)** — `runtime_helpers.zig` `ZNTC_REGISTER_INSTALL`(자기설치형 register, 전 청크) + `ZNTC_IIFE_RESOLVE_BROWSER`(`__zntc_require`/`__zntc_mods`/`__zntc_cache` + env-detect 동적 로더). PR1 의 dormant 중복본은 P3-C 에서 제거 | **상위 확장**: MF2 호환 container/shared scope 를 이 코어 위에 얹음(중복 구현 금지 — 코어 재구현 말 것) |
| 서명/무결성 인프라 | ❌ content hash(Wyhash)만. sha256/SRI/JWT 전무 | **신규**: SHA-256 + RS256 JWT 서명/검증 |

### 6.2 RN / 네이티브 측

| 항목 | 현황 | 결론 |
|---|---|---|
| hermesc 통합 | ⚠️ 테스트에서만 spawn — `tests/integration/tests/hermes-runtime.test.ts:165`, `es5-rn.test.ts:253-276`. 빌드 파이프라인·버전 캡처 없음 | **신규**: .hbc emit 경로 + bytecode 버전 스탬프(매니페스트). 단 user-land hermesc로도 초기엔 충분 |
| 네이티브 lib + npm 배포 | ✅ `packages/core-*` 9개 platform sub-package + `platforms.ts` 자동감지 + `release.yml` 매트릭스 | **재사용(강력)**: `packages/rn-federation-loader` 패키징 템플릿 |
| Zig↔C interop | ✅ `packages/core/src/napi/common.zig`, `napi_entry.zig`, `vendor/node-api-headers` | **재사용 참고**: 패턴은 JSI에 적용 가능(단 JSI는 C++·async·thread affinity로 더 복잡) |
| RN preset | ✅ `src/main.zig:496-589` (flow/worklet/codegen/asset registry/blockList/.ios·.android resolver) | **충돌 없음**: bundler-opts 영역, MF는 런타임 로더 영역 |
| 크로스컴파일 타겟 | ⚠️ native-runner-per-platform(진정한 cross-compile 아님). WASM은 `b.resolveTargetQuery()` 명시 사용 — `build.zig:138-180` | **신규**: iOS/Android Zig 타겟 추가(WASM 패턴 참고) |

### 6.3 막힘(리스크) 항목

- iOS code signing in CI/CD
- Android NDK libc ↔ Zig 호환성(API level)
- JSI thread affinity / async callback / Promise 복잡성
- Hermes 버전별 feature matrix 동적 감지 부재(`src/transformer/compat.zig:651-670`는 고정 preset)

---

## 7. 단계 계획

| Phase | 내용 | 네이티브 |
|---|---|---|
| **P1** | 연합 경계 안정 모듈 ID + MF2 호환 container/registry 런타임 (`runtime_helpers` 신규) | 없음 |
| **P2** | 웹 MF MVP: shared scope + 서명 매니페스트 에미터 + `remoteEntry`. SHA-256/RS256 서명 인프라. metafile 확장. `@module-federation/enhanced` interop 검증 | 없음 |
| **P3** | 빌드타임 계약 검증(D3) + 소유권 경계 린트 | 없음 |
| **P4** | RN: `packages/rn-federation-loader` — Zig 코어 + JSI(TurboModule) + iOS/Android shim. build.zig iOS/Android 타겟 | **C/JSI** |
| **P5** | Hermes .hbc 세그먼트 emit + bytecode 버전 검증 | 코어 확장 |

웹(P1~P3)을 RN(P4~)에 블로킹하지 않는다. **P1 은 §8.1 웹 스파이크 통과가 선행 게이트**(스파이크 산출이 P1 이슈 분해를 결정), P4 는 §8.2 RN 스파이크 0 통과가 선행 게이트.

### 7.1 P1 PR 분해 (스파이크 종결 → 인프라-우선, P3-B 흐름)

스파이크가 D1 실증·제약 5건 포착(§8.1) → 그 제약이 분해를 결정. 각 PR = 한 기능, 독립 테스트 가능, TDD·전체 `zig build test`·app-builder CLI·smoke·`/simplify` 3-agent·rebase auto-merge. 하위 인프라 먼저, emit 은 위에 쌓는다(P3-A/B/C 선례). 재사용: `module_id.zig`(P3-B relative-path 안정 ID), `__zntc_*` 레지스트리 코어(`ZNTC_REGISTER_INSTALL`+`ZNTC_IIFE_RESOLVE_BROWSER`), content-hash 청크, `--external`/`--globals`, `format_wrapper`. **MF2 호환 경계만 — 코어 재구현 금지**(§6.1).

| PR | 내용 | 근거(스파이크/실측) | 의존 |
|---|---|---|---|
| **P1-0** | `mf` config 표면: `zntc.config` MF 블록(`name`/`exposes`/`remotes`/`shared`/`shareScope`) + CLI. emit 없음 | MF2 config 계약 | — |
| **P1-1** | 연합 경계 모듈 식별 + de-opt: `exposes ∪ shared ∪ shared-transitive-폐포` 를 boundary 로 표시 → 스코프 호이스팅 소거 제외·`module_id.zig` 안정 ID 부여. 분석만(emit 없음) | 제약 #1 토대, 스코프호이스팅×경계정체성(S2) | P1-0 |
| **P1-2** | `shared` seam emit: boundary shared 의존을 글로벌-파라미터 seam 자동생성(`--globals` 기계 재사용). container 가 글로벌명 소유 | 제약 #1·#3 (S2 검증 메커니즘) | P1-1 |
| **P1-3** | container emit: `remoteEntry` — 레지스트리 출력을 webpack-style container(`init(shareScope,initScope)`/`get(id):Promise<factory>`, container 를 globalName 대입)로 wrap. init-before-get 강제 | 제약 #2, S1/S3 형태 | P1-2 |
| **P1-4** | `shareScopeMap` 런타임: `scope→pkg→ver→{get,loaded,from,shareConfig}` 유지 + singleton/버전 해석 MF2 시맨틱 + shared→async 강등(entry async/`eager`) | S2, MF2 실측(shareScopeMap·async) | P1-3 |
| **P1-5** | `mf-manifest.json` + `remoteEntry` 에미터: S4 실측 스키마(`id,name,metaData[…],exposes[{id,name,assets{js/css sync/async},path}],shared,remotes`) + content-hash assets 배선 | S4 계약 포착, S5 content-hash 재사용 | P1-3 |
| **P1-6** | host 통합: D1 하이브리드 — host 런타임은 **`@module-federation/runtime`(스펙) 타겟 재사용**(S3 가 공식 런타임이 우리 container 구동 증명 → host 측 자체 재구현 불필요·interop 보장). config→`init` 배선 | S3 PASS, interop 타겟=runtime | P1-4,P1-5 |
| **P1-7** | interop CI 박제: Playwright + `rspack`/`enhanced` 픽스처 — S3 정방향 + **S4 역방향(스파이크 이월분)** 실브라우저 영구 CI | S4 → P1 CI(§8.1) | P1-6 |

분해 트래커: GitHub 이슈 #3318 하위.

> **P3(CJS/IIFE code splitting, 백로그 #3321)과의 통합**: `docs/RFC_CJS_IIFE_CODE_SPLITTING.md` 가
> 요구하는 런타임 require 레지스트리·안정 모듈 ID 는 본 RFC §4.1 의 "연합 경계 안정 모듈 ID +
> registry/container" 와 **같은 하위 인프라**다. **MF P1 착수 시 별도 구현 금지** — 그 RFC 의
> P3-A(최소 require 레지스트리)를 하위 계층으로, MF container 를 상위 계층으로 수렴시킨다.

### 7.2 P2 PR 분해 (웹 MF MVP — 인프라-우선, §7.1 답습)

P1(#3382~#3389)이 MF2 호환 container/registry substrate 를 박제. P2 는 그 위에
**표준 host 가 zntc remote 와 버전 협상**하게 하는 데이터 정합(manifest.shared)·
무결성/서명·관측성(metafile)·interop 확대를 쌓는다. 각 PR = 한 기능, 독립 테스트,
`/simplify` 3-agent, MF 코어 재구현 금지(D1, §6.1).

| PR | 내용 | 근거(RFC/레퍼런스) | 의존 |
|---|---|---|---|
| **P2-0** | manifest.shared 정밀: `buildManifest.shared` 를 `mf.shared`(SharedEntry)→`ManifestShared`(`@module-federation/sdk` manifest 타입) 로 채움. seam 정합(assets 빈 — external+글로벌 seam 이 로딩 담당). #3419 한계 가드 갱신 | §7 "shared scope", #3419 갭, sdk `ManifestShared`/`generateSnapshotFromManifest` | — |
| **P2-1** | host manifest.remotes 반영 (`ManifestRemote`) | §7, sdk manifest 타입 | P2-0 |
| **P2-2** | SHA-256 무결성 다이제스트 인프라 (파일명 Wyhash 불변 — §9 "파일명 Wyhash, 무결성만 SHA-256") | §4.1·§6.1·§9 | P2-0 |
| **P2-3** | RS256 서명 에미터 + verify (manifest 무결성 한정, 표준 부재 → zntc 고유·D3 인접; 런타임 강제 verify 는 P4) | §4.1·§5.4·§9 | P2-2 |
| **P2-4** | metafile MF 산출 표식 확장 (additive only — esbuild 호환 불변) | §6.1 | P2-0 |
| **P2-5** | enhanced interop 확대: shared singleton×표준 rspack remote, 다중 expose, 버전충돌 e2e | §7 "@module-federation/enhanced interop 검증" | P2-0,P2-1 |

인프라-우선: P2-0(데이터 정합) → P2-2(해시) → P2-3(서명, 해시 위에). P2-4/P2-5 는
P2-0 후 병렬. 분해 트래커: GitHub 이슈 #3318 하위 (P1 #3382~#3389 선례).

> **P2 난점·경계**: ① `ManifestShared.version` 출처 — `SharedEntry` 에 실제 설치
> 버전 없음(external+seam 처리). P2-0 은 `required_version` 대용(과설계 회피),
> 정밀 버전 해석(package.json)은 비-목표/후속. ② 서명 표준 부재 —
> `@module-federation/*` 에 sign/verify 없음. P2-3 = manifest 무결성 다이제스트
> 서명까지(표준 host 는 무시), 런타임 강제 verify·remoteEntry 본문 서명은 P4(RN
> 보안 모델). ③ D3 빌드타임 계약 검증·tree-shaking server-calc·named-scope 다중·
> RN 은 P2 비-목표(P3/P4).

### 7.3 P3 PR 분해 (빌드타임 계약 검증 D3 + 소유권 경계 린트 — 인프라-우선, §7.2 답습)

P1(#3382~#3389)·P2(#3420~#3425)가 MF2 호환 substrate + 서명 매니페스트를
박제. P3 는 **그 매니페스트를 host 빌드가 1급 계약으로 읽어 검증**한다 —
MF 2.0 의 stale `.d.ts` CDN 런타임 fetch(§8.1 type-hinting 실측: staleness/
silent-fail) 대비 핵심 차별화(D3). §9 잠정 결정 = **빌드 핀 + 런타임 가드**:
P3-1·P3-2·P3-3 = 빌드 핀(fail-fast, S6), P3-5 = 런타임 가드. 각 PR = 한
기능, 독립 테스트, `/simplify` 3-agent, MF 코어 재구현 금지(D1, §6.1).

| PR | 내용 | 근거(RFC/레퍼런스) | 의존 |
|---|---|---|---|
| **P3-0** | 계약 검증 토대: host 빌드가 `mf.remotes` 의 `mf-manifest.json` 를 resolve+parse → `RemoteContract`{name,exposes[],shared[{name,version,requiredVersion,singleton}]} 데이터 모델. 검증 없음(파싱·표면). P2-0/P2-1 sdk Manifest 타입 단일 재사용 | §4.1 D3, §7, P2-0/1 manifest | — |
| **P3-1** | expose 계약 검증: host 가 import 하는 `<remote>/<subpath>` 가 remote manifest.exposes 에 부재 시 **빌드 fail-fast**(S6 핵심 — 런타임 깨짐 아님) | S6, §4.1 D3 | P3-0 |
| **P3-2** | shared 버전 호환 검증: host `shared` requiredVersion(semver range) vs remote manifest.shared.version 교차 + singleton 불일치 — 위반 시 fail-fast/경고(semver 비교 유틸) | §3.4 버전축, §4.1 D3 | P3-0 |
| **P3-3** | 무결성 빌드타임 검증: host 빌드가 remote sidecar(P2-2 SHA-256 / P2-3 Ed25519)를 stale/변조 시 fail-fast — D3 "런타임 가드"의 빌드타임 절반 | §4.1 D3, §9, P2-2/3 | P3-0 |
| **P3-4** | 소유권 경계 린트: remote/shared 경계 모듈이 host-owned store/Provider 를 자체 생성(Redux `configureStore`/`createStore`·Zustand `create`·Jotai `createStore`) → **비-차단 빌드 경고**(AST 휴리스틱, non-literal dynamic import 경고 #3336 선례) | §3.2 (line 54), §4.1 D3 | P3-0 |
| **P3-5** | 런타임 가드 폴백 emit + interop e2e: 계약 불일치 시 런타임 graceful fallback emit + 표준 `@module-federation/enhanced` 로 빌드-fail(S6) & 런타임-가드 양쪽 영구 박제 | §9 "빌드 핀+런타임 가드", S6, P2-5 하네스 | P3-1,P3-2,P3-3 |

인프라-우선: P3-0(파싱·데이터 정합) → P3-1·P3-2·P3-3(빌드 핀 검증, P3-0 후 병렬) → P3-4(린트, P3-0 후 병렬) → P3-5(런타임 가드 + interop, 검증 단위 위에). 분해 트래커: GitHub 이슈 #3318 하위 — **P3-0 #3435 · P3-1 #3436 · P3-2 #3437 · P3-3 #3438 · P3-4 #3439 · P3-5 #3440** (P1 #3382~, P2 #3420~ 선례).

> **P3 난점·경계**: ① store 계약 패키지(`@app/store-contract@x.y.z`)의
> expand-contract 진화 자동 강제 = 사용자 규율/문서 — zntc 는 **검증만**,
> 계약 정의 생성·강제는 비-목표. ② 소유권 린트(P3-4)는 휴리스틱 경고
> (false-positive 가능, **비-차단**) — 완전 데이터플로 분석은 비-목표.
> ③ remote manifest 의 빌드타임 **HTTP fetch(네트워크 다운로드)**는 P3-0
> 가 local/file resolve 우선, 네트워크 fetch·캐시·신뢰 모델은 P4(RN 보안
> 모델)/후속. ④ `.d.ts` 타입힌트 **생성**(MF2 `@mf-types` 대응물)은 D3
> 차별화의 별도 축 → 후속/비-목표(P3 는 *검증*, 타입 생성 아님).
> ⑤ RN = P4.

---

## 8. 디리스크 스파이크

전체의 95%를 짓기 전에 위험한 5%부터. 두 스파이크는 각 페이즈의 **go/no-go 게이트** — 통과 못 하면 그 페이즈 진입 금지(P3-B 디리스크 패턴 답습: 손수 픽스처 + 최소 런타임으로 Node/브라우저 증명 → 검증 후 산출물 폐기, 동작은 영구 테스트로 박제).

### 8.1 웹 스파이크 (P1 게이트 — 지금 수행, D6: 웹 먼저)

**증명 대상(가장 불확실한 5%)**: P3-B 가 만든 `__zntc_*` 레지스트리 코어 위에 얹을 MF2 호환 경계가 **실제 `@module-federation/enhanced` 와 양방향으로 맞물리고, shared 단일성·부분 재배포가 성립하는가.** 깨지면 D1(MF2 호환 경계)·D2(shared 핀) 재논의 — P1 한 줄 짜기 전에 본다.

**픽스처 (손수 작성, 버리는 코드)**

| 이름 | 역할 | 비고 |
|---|---|---|
| `remote-a` | zntc 빌드. `./Widget` 1개 expose, `react` shared | zntc emit: `remoteEntry` + `mf-manifest.json` + content-hash 청크 |
| `remote-b` | zntc 빌드. `./Card` expose, `react` shared(같은 버전 핀) | 두 remote 가 react 단일 인스턴스 공유 검증용 |
| `host-zntc` | zntc 빌드. `remote-a`·`remote-b` 소비 (정적 + 동적 `import("remote-a/Widget")`) | 우리 host |
| `host-mf2` | **`@module-federation/enhanced` (webpack/rspack)** host. `remote-a` 소비 | interop — 표준 host 가 우리 remote 를 먹나 |
| `remote-mf2` | `@module-federation/enhanced` remote. `host-zntc` 가 소비 | interop 역방향 — 우리 host 가 표준 remote 를 먹나 |

origin 분리는 로컬 정적 서버 N개(포트 다름)로 시뮬, `__zntc_public_path`/MF `publicPath` 로 remote URL 주입.

**MF2 계약 실측** (docs.module-federation.io 정독 — 계약/제약 페이지 한정; 빌드툴별 플러그인 내부·framework bridge 는 우리 계약과 무관해 제외):

- **interop 타겟 = `@module-federation/runtime`** (스펙·번들러 무관, 독립 동작). `@module-federation/enhanced` = webpack/rspack *빌드 플러그인* + 런타임 → 우리는 enhanced 를 **표준 host/remote 테스트 피어**로만 쓰고, emit 은 `@module-federation/runtime` 계약을 타겟(D1 정밀화).
- **container 계약**: `init(shareScope, shareScopeObject)` + `get(expose) => () => Module` — RFC §4.1 과 일치(실측 확인).
- **shareScopeMap 정확 스키마**(우리 shared scope 가 emit·유지해야 할 in-memory 구조): `scope → pkgName → version → { get, loaded, from, shareConfig }`. named scope 다중 지원 필요(default 만으론 부족 — gradual upgrade/도메인 격리).
- **치명 제약**: shared 로 지정된 모듈은 **비동기 모듈로 강등** → entry 가 async 거나 `eager:true` 여야 함. 아니면 `"Shared module is not available for eager consumption"`. singleton 위반 = React 중복 인스턴스(hook 깨짐). init 순서 위반(RUNTIME-009). cross-origin CORS/credential.
- **shared-tree-shaking 은 cross-build DCE 아님**(공식 명시): server-calc = CI 가 각 빌드 `usedExports` 수집→합집합→shared 2차 빌드(우리 D3/빌드타임 철학과 정합, 흡수 대상). runtime-infer = 런타임 hit+full fallback, **singleton 과 충돌(인스턴스 분열)**.
- **type-hinting**: `.d.ts`→CDN 런타임 fetch(`@mf-types`), staleness/silent-fail — 우리 **D3 빌드타임 계약 검증이 정당한 차별화**(실측으로 약점 확인).
- **CSS**: MF2 는 런타임 CSS 격리를 **의도적으로 안 함**(shared 와 충돌). producer-side 격리(CSS Modules/BEM) 권장 → zntc 의 기존 CSS 코드스플리팅+`<link>` 주입과 호환. **federation 런타임 CSS 샌드박싱을 만들지 말 것**(over-engineering 금지).
- **RN/Metro MF 는 experimental**, 네이티브 로딩 메커니즘 문서 미명시·Re.Pack 무언급 → D4(자체 C/JSI 로더)와 **충돌 없음**, §8.2 가 여전 RN 게이트.
- **data-fetch**: 컴포넌트 단위 data loader 만, shared store/server-state 의견 없음(RSC "탐색 중") → RFC §3(상태 소유권 설계)은 MF2 대비 **앞선 차별화**(갭 아님).

**검증 단계 & 통과 기준**

> **청크 실브라우저 e2e 통합(S0)**: 현재 청크 동적 로더(JS `<script>` 주입·CSP nonce·Worker `importScripts`·`import(url)`)는 통합테스트에서 **Node `document`/`importScripts` 스텁(시뮬)** 으로만 검증되고, 실브라우저 e2e 는 CSS `<link>` 1개뿐(JS 동적 청크/CSP 실 정책 갭). 스파이크 하네스가 실 Playwright + 다중 origin + 실 CSP 헤더를 어차피 요구하므로, 이 갭을 **S0 로 흡수**해 한 번에 메운다 — S0 통과분은 chunk e2e + MF 하네스 양쪽으로 박제.

| # | 무엇 | 환경 | PASS 기준 |
|---|---|---|---|
| **S0** | **청크 런타임 실브라우저 기준선**(MF 무관, 순수 코드스플리팅): 동적 `import()` 청크가 실 `<script>` 주입으로 로드·실행, CSP `script-src 'nonce-…'` 정책 하에서 nonce 스크립트 **브라우저가 실제 허용**, Worker `importScripts`/`import(url)` 분기 | **실 Playwright** + 정적서버(실 `Content-Security-Policy` 헤더) | 동적 청크 코드 실행·DOM 반영, CSP 위반 0(블록된 스크립트 없음), worker 경로 로드 — Node 스텁이 못 잡던 실브라우저 동작 증명 |
| S1 | `host-zntc` 가 `remote-a/Widget` 정적 + `remote-b/Card` 동적 로드·렌더. **shared→async 강등 처리**(entry async/`eager` 경로) + `init(shareScope)`/`get(expose)` 계약 + `shareScopeMap` 스키마 emit | Node + Playwright(headless) | DOM 에 두 컴포넌트 렌더, 콘솔 에러 0, `"eager consumption"`/RUNTIME-009 0 |
| S2 | `react` shared 단일 인스턴스 — **(a) 일반 (b) shared-tree-shaking(runtime-infer) 켠 상태** 둘 다 | 위와 동일 | `useState`/Context 가 경계 넘어 동작(인스턴스 1개). (b) 에서도 singleton 유지(tree-shaking×singleton 분열 회피 확인 — 안 되면 우리도 동일 제약 명시) |
| S3 | **interop 정방향**: `host-mf2`(enhanced) 가 zntc `remote-a` 로드 | Node + Playwright | 표준 host 에서 zntc remote 렌더, MF2 런타임 계약 위반 0 |
| S4 | **interop 역방향**: `host-zntc` 가 `remote-mf2` 로드 | 〃 | 우리 host 가 표준 remote 렌더 |
| S5 | **부분 재배포(엔드유저 가치 A)**: `remote-a/Widget` 만 수정 후 재빌드·재배포, `host-zntc` 무수정 | Node | 바뀐 content-hash 청크만 교체, host 청크 해시 불변, 갱신된 Widget 렌더 |
| S6 | 빌드타임 계약 불일치(D3 맛보기): `remote-a` export 시그니처 변경 후 `host-zntc` 재빌드 | `zig build` | 빌드 fail-fast(런타임 깨짐 아님) |

**S0 실패 → 청크 동적 로더/CSP 실브라우저 회귀(MF 무관, 즉시 수정 — P1 진입 전 차단).** S1·S2 실패 → 레지스트리 코어/공유 스코프 설계 결함(P3-C 수렴 가정 재검토). **S3·S4 실패 → D1 재논의(가장 치명적, "진짜 된다"의 핵심 증거).** S5 실패 → 청크/해시 경계 설계 결함. S6 는 P3 기능 선검증(실패해도 P1 진입 가능, P3 범위로 이월).

**산출물 위치/정리**: `tests/benchmark/_mf_web_spike/` (untracked, oxfmt pre-push 오염 방지 위해 검증 후 `rm`). 박제: **S0 → `tests/e2e/` 실브라우저 청크 e2e(JS 동적청크+CSP, 기존 css-code-splitting-e2e 와 나란히 — 청크 갭 영구 메움)**, S1·S2·S5 → `tests/integration/tests/mf-web-*.test.ts`, 브라우저 경로(S1·S3·S4) → Playwright `tests/e2e/` (P3-B 스파이크→테스트 박제 선례). `@module-federation/enhanced` 는 devDependency 로 **버전 핀 고정**(생태계 변동 추적, RFC §9).

통과 시 §8.1 산출이 P1 이슈 분해를 직접 결정(스파이크가 잡은 제약 → PR 분해, P3-B 와 동일 흐름).

**스파이크 진행 결과 (2026-05, Node-first + S0 실브라우저)**

- **S0 PASS** — 실 Chrome + 실 CSP `script-src 'nonce-…'`, IIFE 동적청크 `<script>` 주입 nonce 허용·실행. 영구 e2e 박제(PR #3377).
- **S1 PASS** — zntc 스코프 호이스팅 IIFE 출력을 손수 MF2 container 계약(`init(shareScope)`/`get(expose)=>()=>Module`)으로 감싸 host 가 로드·get·실행. **레지스트리 코어가 MF container substrate 로 성립.**
- **S2 PASS** (가장 치명 미지수 #1/#2) — host 가 shared 인스턴스 소유·shareScope 등록 → `container.init(shareScope)` 가 widget eval *전* 글로벌 seam 채움 → **독립 스코프 호이스팅 빌드 양측이 shared 인스턴스 1개**(host 2회 bump→remote 3·4, identity 일치). 스코프 호이스팅×연합 경계 정체성 충돌이 seam 으로 해소됨 → **D1 가정 성립.**
- **S5 PASS** — 미변경 모듈의 content-hash 청크가 독립 재빌드에서 **byte-동일**(`core-98588766.js` 불변), 변경 widget 청크만 새 hash+새 코드. 부분 재배포(가치 A)·cross-build 결정성(리스크 #5) 검증.
- **S3 PASS** — 공식 `@module-federation/runtime@2.4.0`(= 문서가 명시한 *실제 interop 계약* 패키지, enhanced 아님)이 zntc-output 기반 container 를 자기 `init`/`loadRemote` resolution 파이프라인으로 구동·실행. **표준 런타임 ↔ zntc remote interop 성립**(정방향). 부수 확인: `RUNTIME-009`(createInstance 전 registerPlugins 금지 → plugins 는 init 옵션) — RFC MF2 실측 #2 와 일치.
- **S4 부분 — 계약 포착, 실행 interop 은 P1 브라우저 CI 로 스코핑**. 표준 빌드툴(`@rspack/[email protected]` + `@module-federation/[email protected]`)로 **진짜 remote 빌드 성공**(`remoteEntry.js`/`mf-manifest.json`/`__federation_expose_*`). 그 산출 계약을 zntc MF emit 타겟으로 실측 박제: **mf-manifest** = `{id,name,metaData[name,type,buildInfo,remoteEntry,types,globalName,pluginVersion,publicPath], exposes[{id,name,assets{js{sync,async},css{...}},path}], shared, remotes}`; **remoteEntry** = webpack-style container(`init`/`get`, `get(id):Promise<factory>`, `moduleMap`, container 를 globalName 에 대입). Node 실행 실패(auto-publicPath/`self`/webpack chunk-global)는 **web-타겟 remote 를 Node 에 넣은 환경 잡음 — 계약 실패 아님**. web remote 의 런타임 실행 interop 은 본질상 브라우저 시나리오 → S3 가 런타임 *계약* 양방향(동일 resolution 코드경로)을 이미 증명했으므로, S4 실행 확증은 **P1 interop CI(Playwright + 검증된 rspack 픽스처)** 로 이월(toolchain 설치 가능 확인됨).
- **S6** — zntc 빌드타임 계약 검증은 P3 기능(현재 전무) → RFC 대로 P1 비차단, P3 로 이월.

**스파이크 종결 판정**: 핵심 D1 리스크(S1 substrate·S2 단일성·S3 표준 런타임 interop)와 가치 A(S5)·청크 런타임(S0) **전부 PASS**. S4 실행은 P1 브라우저 CI, S6 은 P3 — 둘 다 RFC상 P1 비차단. **→ D1(자체 코어 + MF2 호환 경계) 가정 실증 완료, P1 이슈 분해 진입 가능.**

**스파이크가 잡은 P1-결정 제약** (P3-B 선례 — 제약이 PR 분해를 결정):

1. **zntc IIFE 는 bare external import emit 불가**("no require/import in factory scope") → MF emit 은 모든 `shared`/`remote` 의존을 **`--globals` 식 글로벌-파라미터 seam 으로 자동 생성**해야 함(container 가 글로벌명 소유·주입). P1 의 핵심 emit 작업.
2. **순서 제약**: `container.init(shareScope)` 가 shared 글로벌을 exposed 번들 eval *전*에 설치해야 함 — MF2 `init`-before-`get` 계약과 일치(우리 모델 호환).
3. zntc 는 shared 멤버를 module-init 에 destructure(`var x = G.x`) — object/function namespace(react 등)는 live ref 로 OK, 재대입 바인딩은 snapshot(실 shared 는 namespace 라 무해, 문서화).
4. content-hash 청크는 미변경 모듈에 cross-build 결정적 → 부분 재배포 가능. 단 규모 확대 시 비결정 소스(해시맵 순회·임시명) 지속 감사 필요.
5. 단일-엔트리 번들은 stdout 출력(`--splitting` 시 파일) — MF emit 이 출력 경로 제어하므로 영향 없음(하네스 노트).

→ S1/S2/S5 PASS 로 **레지스트리/스코프 호이스팅 코어가 MF 의 viable substrate 임이 실증**. S3/S4(생태계 interop) 만 남음.

### 8.2 RN 스파이크 0 (P4 게이트 — 웹 P1~P3 후, D6)

> 버리는 TurboModule 하나 — 로컬 파일을 JSI `evaluateJavaScript`로 살아있는 런타임에 주입해 federated 모듈이 등록·렌더되는지를 **(a) JS 소스 (b) 사전컴파일 .hbc** 두 경우로, **New Arch + Hermes**에서 증명.

통과 시 나머지(Zig 코어, HTTP shim, 캐시, 서명)는 위험도 낮은 정공법. 실패 시 D4(자체 로더) 재검토. **이게 RN 전체의 go/no-go** — 웹(P1~P3)을 블로킹하지 않음(D6).

---

## 9. 미해결 / 추가 논의

- iOS code signing을 CI에서 어떻게 풀 것인가(또는 macOS runner 네이티브 빌드 유지)
- Android NDK API level 하한 결정
- 계약 검증 시점: remote 빌드 핀 vs host 배포 검증 vs 런타임 가드 — 조합 비율(논의 잠정: 빌드 핀 + 런타임 가드)
- Wyhash → SHA-256 전환 범위(파일명은 Wyhash 유지, 무결성만 SHA-256인지)
- MF2 런타임 contract의 정확한 버전 고정(생태계 변동 추적 비용)

---

## 부록: 참고 코드 위치

- 청크/해시: `src/bundler/emitter/chunks.zig` (230-301, 948-1051, 1281-1339)
- metafile: `src/bundler/bundler.zig:1612-1677`
- 모듈/링커: `src/bundler/module.zig`, `src/bundler/linker.zig`
- 런타임 헬퍼: `src/bundler/runtime_helpers.zig`, `src/runtime_helper_modules.zig`
- NAPI/Zig↔C: `packages/core/src/napi/common.zig`, `src/napi_entry.zig`, `vendor/node-api-headers/`
- 패키징: `packages/core-*/`, `packages/core/src/platforms.ts`, `.github/workflows/release.yml`
- 빌드/타겟: `build.zig` (50-287 NAPI, 138-180 WASM 타겟 패턴)
- RN preset: `src/main.zig:496-589`, hermesc: `tests/integration/tests/hermes-runtime.test.ts`
