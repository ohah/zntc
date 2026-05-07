# RN Codegen Snapshot 회귀

ZNTC native codegen 의 출력이 `@react-native/codegen` reference 출력과
**의미적으로 동등** (RN runtime 이 등록하는 attribute / event 키 set 일치) 한지
검증하는 fixture 모음. ZNTC PR #2348 의 contract: reference 와 동등 결과 emit 이
곧 RN 호환 보장.

## 디렉토리 구조

```
codegen-snapshots/
├── README.md
└── rn-<version>/
    ├── fixtures/    # *NativeComponent.{ts,js} spec 파일 (vendored from npm)
    └── golden/      # @react-native/codegen 이 emit 한 view config (script 가 생성)
```

suite 디렉토리명은 `rn-<MAJOR>.<MINOR>` 컨벤션. 같은 디렉토리 안에는 RN core
spec 과 자주 쓰이는 라이브러리 spec (svg, screens, safe-area-context 등) 의
fixture 가 같이 들어감 — 모두 같은 RN 버전의 codegen reference 로 골든을 생성하므로.
출처는 fixture 파일 안에 inline 주석 또는 본 README 의 suite 표로 트래킹.

현재 suite:

| Suite      | 출처                                                                                                                                       | 비고                                                                                                           |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `rn-0.78/` | RN 0.78-stable `packages/react-native/src/private/specs/components/` (3 spec — DebuggingOverlay / ActivityIndicatorView / RCTSafeAreaView) | Flow + 이전 codegen emit 패턴                                                                                  |
| `rn-0.79/` | RN 0.79-stable `packages/react-native/src/private/specs_DEPRECATED/components/` (동일 3 spec)                                              | 0.79 부터 spec 위치가 `specs_DEPRECATED/` 로 이동. emit 형태는 0.78 와 cosmetic 차이만 (single → double quote) |
| `rn-0.80/` | RN 0.80-stable `specs_DEPRECATED/components/` (동일 3 spec)                                                                                | 0.79 와 emit 동일 (cosmetic only)                                                                              |
| `rn-0.81/` | RN 0.81-stable `specs_DEPRECATED/components/` (동일 3 spec)                                                                                | 0.80 와 emit 동일                                                                                              |
| `rn-0.82/` | RN 0.82-stable `specs_DEPRECATED/components/` (동일 3 spec)                                                                                | 0.81 와 emit 동일                                                                                              |
| `rn-0.83/` | RN 0.83-stable `specs_DEPRECATED/components/` (동일 3 spec)                                                                                | 0.82 와 emit 동일                                                                                              |
| `rn-0.84/` | RN 0.84-stable `specs_DEPRECATED/components/` (동일 3 spec)                                                                                | 0.83 와 emit 동일                                                                                              |
| `rn-0.85/` | react-native-screens 4.23.0 (4 spec)                                                                                                       | RN 0.85+ namespace alias 표준 채택. TS 패턴                                                                    |

## Reference (untracked)

`references/react-native-codegen-<version>/` 는 `.gitignore` 대상 (`references/`
전체) — vendored 자료는 commit 하지 않고 각 dev/CI 환경이 fetch. 디렉토리명
`<version>` 부분이 suite 의 `rn-<version>` 과 정확히 일치해야 함 (script 가 그
값으로 reference 위치를 결정).

RN 버전마다 한 번:

```bash
VERSION=0.85
RNC=/path/to/node_modules/@react-native/codegen   # 인접 RN 프로젝트 또는 npm pack 결과
mkdir -p "references/react-native-codegen-${VERSION}"
cp -r "$RNC/lib" "$RNC/package.json" "references/react-native-codegen-${VERSION}/"
# 원본 prepare 가 `rimraf lib` → build 라서 bun install 시 vendored lib 삭제됨.
# scripts 비우기 필수.
jq '.scripts = {}' "references/react-native-codegen-${VERSION}/package.json" \
  | sponge "references/react-native-codegen-${VERSION}/package.json"
( cd "references/react-native-codegen-${VERSION}" && bun install --ignore-scripts )
```

## Golden 재생성

새 fixture 추가 / RN 새 버전 vendoring 시:

```bash
bun scripts/generate-codegen-golden.mjs                 # 모든 suite × 모든 fixture
bun scripts/generate-codegen-golden.mjs ScreenNative    # 모든 suite, 파일명 substring 매칭
bun scripts/generate-codegen-golden.mjs --suite rn-0.85 # 특정 suite 만
```

Script 는 suite 이름에서 RN 버전을 추출 (`rn-0.85` → `0.85`) 하고 그에 매칭되는
`references/react-native-codegen-0.85/` 를 사용. 매칭 reference 가 없으면 해당
suite 만 skip + 에러 — 다른 suite 는 계속 진행.

골든은 commit 됨 — CI 가 reference 재install 없이 ZNTC 출력만 비교 가능.

## ZNTC 측 검증

`src/transformer/plugins/rn_codegen/snapshot_test.zig` 가 각 suite 의 fixture
마다 ZNTC plugin 출력 vs golden 의 의미적 동등성 (key set) 검증. 새 suite 추가 시
같은 파일에 test block 한 묶음 추가.

## 새 RN 버전 추적

운영 정책 (#2348 anchor):

1. RN minor 출시 → `node_modules/@react-native/codegen` 의 새 버전을
   `references/react-native-codegen-<NEW>/` 로 vendoring (위 절차)
2. `tests/codegen-snapshots/rn-<NEW>/` 디렉토리 생성 + 적절한 spec fixture 복사
3. `bun scripts/generate-codegen-golden.mjs --suite rn-<NEW>` 로 골든 생성
4. `snapshot_test.zig` 에 test block 추가
5. `zig build test` 로 byte-diff 회귀 detect → 깨진 패턴은 schema_builder /
   emitter 에 추가
