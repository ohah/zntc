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
| module registry / container 런타임 | ⚙️ **P3-B PR1 에서 최소 레지스트리 구현됨** — `runtime_helpers.zig` `ZNTC_REGISTRY_RUNTIME`(`__zntc_mods`/`__zntc_require`/`__zntc_register`/`__zntc_load_chunk`) | **상위 확장**: MF2 호환 container/shared scope 를 이 레지스트리 위에 얹음 |
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

웹(P1~P3)을 RN(P4~)에 블로킹하지 않는다.

> **P3(CJS/IIFE code splitting, 백로그 #3321)과의 통합**: `docs/RFC_CJS_IIFE_CODE_SPLITTING.md` 가
> 요구하는 런타임 require 레지스트리·안정 모듈 ID 는 본 RFC §4.1 의 "연합 경계 안정 모듈 ID +
> registry/container" 와 **같은 하위 인프라**다. **MF P1 착수 시 별도 구현 금지** — 그 RFC 의
> P3-A(최소 require 레지스트리)를 하위 계층으로, MF container 를 상위 계층으로 수렴시킨다.

---

## 8. 디리스크: 스파이크 0 (RN 최우선 검증)

전체의 95%를 짓기 전에 위험한 5%부터:

> 버리는 TurboModule 하나 — 로컬 파일을 JSI `evaluateJavaScript`로 살아있는 런타임에 주입해 federated 모듈이 등록·렌더되는지를 **(a) JS 소스 (b) 사전컴파일 .hbc** 두 경우로, **New Arch + Hermes**에서 증명.

통과 시 나머지(Zig 코어, HTTP shim, 캐시, 서명)는 위험도 낮은 정공법. 실패 시 D4(자체 로더) 재검토.

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
