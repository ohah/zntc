# 토론: WASM (WASI) 플러그인 호스트

> **상태**: 토론 단계 (미결정). 결정되면 본 문서를 design doc으로 승격.
> **선행 조건**: AST 안정화 (별도 토론 문서)

## 1. 한 줄 요약

사용자 플러그인을 **WebAssembly로 컴파일하여 ZTS 안에서 실행**하게 하는 시스템.
사용자는 Rust/Zig/AssemblyScript/Go(TinyGo)/C++ 등으로 작성, ZTS는 `.wasm`을 로드해서 transform pass에 주입.

## 2. 동기 (Why)

### 현재 ZTS 플러그인의 한계

| 방식 | 제약 |
|---|---|
| NAPI plugin (JS/TS) | Node 환경 필요. WASM 빌드(브라우저 Playground)에서 미지원. JS↔native 왕복 비용. |
| AST plugin (Zig) | ZTS 소스를 직접 수정해야 함 — 사용자 불가. |

### WASM 플러그인이 해결

- **언어 자유**: Rust/Zig/AssemblyScript/Go(TinyGo)/C++ — 사용자 선호 언어
- **속도**: JS 대비 5~50배 (네이티브 WASM)
- **샌드박스**: WASI 권한으로 fs/env 접근 제어 (보안 경계 명확)
- **이식성**: 한 번 컴파일하면 ZTS의 native·NAPI·WASM 빌드 어디서나 동일 동작
- **생태계 흡수**: swc-plugin ABI 호환 시 Next.js의 SWC 플러그인 그대로 사용 (`@swc/plugin-emotion` 등)

## 3. 산업 사례

### SWC (Next.js)
- `swc_plugin` Rust crate, `wasm32-wasi` 타겟
- AST를 **rkyv** (Rust 직렬화 라이브러리)로 직렬화해서 WASM 메모리 전달
- `next.config.js`에 `experimental.swcPlugins: [['my-plugin', {}]]`
- 단점: AST schema 변경에 매우 민감 (swc 마이너 버전마다 깨짐)

### oxc / Rolldown
- WASI plugin host 논의 단계, 정식 출시 X
- 현재는 native Rust crate plugin만

### esbuild / Vite
- WASM plugin 없음. JS plugin만.

### Bun
- 자체 native plugin API만, WASM 미지원

### Parcel
- WASM 자체는 자산(asset)으로만, plugin 호스트 X

## 4. 설계 옵션

### 4.1 WASM runtime 선택

| 런타임 | 장단점 |
|---|---|
| **Wasmtime** (Rust) | 안정·표준. Zig embed는 C API 통해 가능. 바이너리 크기 ~5MB. |
| **Wasmer** (Rust) | Wasmtime과 유사. WASIX 지원. |
| **WAMR** (C) | 작음 (~1MB). 임베드 친화. |
| **Wasm3** (C) | 매우 작음 (~256KB). 인터프리터라 느림. |
| **자체 구현** | 비현실적. |

**권장**: WAMR (C) — 바이너리 부담 작음, Zig에서 C ABI 통해 호출 쉬움. 성능 부족 시 Wasmtime으로 교체.

### 4.2 AST 직렬화 ABI

플러그인이 ZTS AST를 어떻게 보고 수정하나?

| 옵션 | 특징 |
|---|---|
| **A. AST 통째 직렬화 (rkyv/protobuf/flatbuffers)** | swc 방식. 매번 큰 메모리 복사. 단순. |
| **B. AST 노드 단위 핸들 + 호스트 함수** | oxc 검토 중인 방식. 빠름. ABI 복잡. |
| **C. Source string in/out (no AST)** | 가장 단순. 트랜스폼만 가능, 노드 순회 X. Phase 1 추천. |
| **D. estree JSON in/out** | 표준 호환, parse/print 비용 큼. |

**권장 단계**:
1. **Phase 1: C** (string in/out) — 단순 macro/codemod 수준
2. **Phase 2: A or B** (AST 노출) — visitor 패턴
3. **Phase 3: swc-plugin ABI 호환 레이어** — swc 플러그인 그대로 동작

### 4.3 호스트 함수 (host imports)

WASM 플러그인이 호출 가능한 ZTS 함수:

- `zts.error(level, message)` — 에러/경고 보고
- `zts.read_file(path)` — (WASI 권한 시) 파일 읽기
- `zts.resolve(specifier, importer)` — 모듈 resolution
- `zts.ast_get(node_id)` / `zts.ast_replace(node_id, new)` — Phase 2
- `zts.intern(string) → id` — 식별자 풀

### 4.4 WASI 권한 모델

기본 deny-all, plugin manifest로 명시 허용:

```toml
# my-plugin.toml
[wasi]
fs.allow = ["./node_modules/my-plugin/templates"]
env.allow = ["NODE_ENV"]
network = false
```

## 5. ZTS 입장 트레이드오프

### 찬성
- **swc-plugin 흡수** = Next.js 사용자 즉시 마이그레이션 (큰 시장)
- **AST 안정화 ROI 즉시 회수** — WASM 노출이라는 구체적 사용처
- **브라우저 Playground 가치 ↑** — WASM 빌드도 플러그인 실행
- **언어 다양성** — Rust 커뮤니티 흡수 (oxc 전성기 대응)

### 반대
- **AST 안정화 prerequisite** (XL 작업 선행)
- **WASM 런타임 임베드** = 바이너리 크기 +1~5MB
- **swc ABI 호환** = swc 변경 따라가야 (moving target). swc 메이저 버전마다 호환성 깨짐
- **AST 직렬화 비용** — rkyv도 큰 모듈에선 부담. swc도 이 문제로 plugin 성능 별로
- **테스트 매트릭스 폭증** — native, NAPI, WASM, WASM+plugin 4축

## 6. 단계별 스코프 (작게 시작)

### Phase 0: 사전 (1~2주)
- WAMR 임베드 PoC
- "hello world WASM 플러그인" 호출 검증

### Phase 1: String transform (M, ~1개월)
- ABI: `transform(input_ptr, input_len) → output_ptr, output_len`
- Source string in, source string out — 노드 순회 없음
- Use case: 단순 macro, JSX 슈가 등

### Phase 2: AST visitor (L, ~2~3개월)
- AST 안정화 완료 후
- 노드 직렬화 ABI (rkyv 또는 자체 binary format)
- Visitor 패턴 — `enter(node)`, `exit(node)`, `replace(new)`
- Use case: 본격 트랜스폼 (`@swc/plugin-styled-components` 수준)

### Phase 3: swc-plugin 호환 (L, ~1~2개월)
- swc plugin ABI 미러 (rkyv schema 동일)
- Tag/Node 매핑 어댑터
- 검증: 인기 swc 플러그인 (`@swc/plugin-emotion`, `@swc/plugin-styled-components`) 통과

### Phase 4: WASI 추가 (M, ~3~4주)
- 파일 IO, env, time
- Asset 로더 플러그인 가능 (이미지/CSS preprocessor)

## 7. 결정해야 할 것 (Open Questions)

1. **WASM runtime**: WAMR vs Wasmtime?
2. **시작 단계**: Phase 1만 (string transform)? 아니면 Phase 2 (AST)까지 한 번에?
3. **swc ABI 호환 우선순위**: 처음부터 호환 vs 자체 ABI 후 별도 어댑터?
4. **Browser WASM 빌드에서 WASM 플러그인**: 가능? (WASM in WASM — 가능하지만 큰 작업)
5. **빌드 크기 허용치**: 현재 zts.wasm 크기 + plugin runtime이 얼마까지 OK?
6. **Plugin 배포 채널**: npm? Cargo? 자체 레지스트리?
7. **Plugin manifest 형식**: TOML/JSON/JS?

## 8. 우선순위 / 일정 권장

**선행 조건 미해결 (블록)**: AST 안정화

**AST 안정화 후 (이상적 순서)**:
1. Phase 0 (PoC, 2주)
2. Phase 1 (string transform, 1개월) — 최소 가치 출시
3. Phase 4 일부 (WASI 기본만, 1주)
4. Phase 2 (AST visitor, 2~3개월) — 본격 활용
5. Phase 3 (swc 호환, 1~2개월) — 생태계 흡수

**총 예상**: 6~8개월 (AST 안정화 별도)

## 9. 대안 (WASM 안 하는 경우)

- **NAPI plugin 강화**: JS plugin 그대로 두고 NAPI 개선 — 브라우저 미지원이 단점
- **JS plugin in WASM (QuickJS embed)**: WASM 대신 JS interpreter 임베드 — 느림
- **Native Zig plugin loader**: dlopen 기반 — 보안/이식성 문제

대안들 모두 WASM의 "샌드박스 + 이식성 + 언어 자유" 셋을 동시에 만족 못 함.

## 10. 참고 자료

- SWC plugin 문서: https://swc.rs/docs/plugin/ecmascript/getting-started
- WAMR: https://github.com/bytecodealliance/wasm-micro-runtime
- Wasmtime: https://wasmtime.dev/
- WASI snapshot 1: https://github.com/WebAssembly/WASI
- rkyv: https://rkyv.org/

## 11. 후속 액션

이 문서가 design doc으로 승격될 때:
- [ ] 결정 사항을 `DECISIONS.md`에 기록
- [ ] AST 안정화 design doc과 의존 관계 명시
- [ ] PoC 브랜치 (`exp/wasm-plugin-poc`) 생성
