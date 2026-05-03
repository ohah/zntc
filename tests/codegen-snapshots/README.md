# RN Codegen Snapshot 회귀

ZTS native codegen 의 출력이 `@react-native/codegen` reference 출력과
**byte-level 동등** (diff = 0) 한지 검증하는 fixture 모음. ZTS PR #2348 의
contract: reference 와 동등 결과 emit 이 곧 RN 호환 보장.

## 디렉토리 구조

```
codegen-snapshots/
├── README.md
└── <suite>/
    ├── fixtures/    # *NativeComponent.{ts,js} spec 파일 (vendored from npm)
    └── golden/      # @react-native/codegen 이 emit 한 view config (script 가 생성)
```

현재 suite:

| Suite | 출처 | 비고 |
| --- | --- | --- |
| `rn-screens-4/` | react-native-screens 4.23.0 | RN 0.85+ namespace alias 표준 채택. ZTS 가 byte-diff 0 까지 가야 할 4 spec |

## Reference (untracked)

`references/react-native-codegen/` 는 `.gitignore` 대상 — vendored 자료는 commit
하지 않고 각 dev/CI 환경이 fetch. RN minor 출시 마다 한 번:

```bash
RNC=/path/to/node_modules/@react-native/codegen   # 인접 RN 프로젝트 또는 npm pack
mkdir -p references/react-native-codegen
cp -r "$RNC/lib" "$RNC/package.json" references/react-native-codegen/
# 원본 prepare 가 `rimraf lib` → build 라서 bun install 시 vendored lib 삭제됨.
# scripts 비우기 필수.
jq '.scripts = {}' references/react-native-codegen/package.json | sponge references/react-native-codegen/package.json
cd references/react-native-codegen && bun install --ignore-scripts
```

## Golden 재생성

새 fixture 추가 / RN 새 버전 vendoring 시:

```bash
bun scripts/generate-codegen-golden.mjs               # 전체
bun scripts/generate-codegen-golden.mjs ScreenNative  # 특정 파일만
```

골든은 commit 됨 — CI 가 reference 재install 없이 ZTS 출력만 비교 가능.

## ZTS 측 검증

본 PR (인프라 only) 시점엔 ZTS 측 byte-diff 테스트 미포함. 후속 PR 들이 패턴별로
schema_builder / view_config_emitter 를 보강하면서 spec 단위로 zig integration
test 활성화:

- PR #1 (본 PR): 인프라 + 4 spec golden baseline
- PR #2: `T[]` array type 지원 + ScreenNativeComponent / ScreenStackHeaderConfig 활성화
- PR #3+: 나머지 spec 의 추가 패턴

각 PR 의 zig test 는 `expectEqualStrings(golden, zts_output)` 로 byte-diff 0
보장.

## 새 RN 버전 추적

운영 정책 (#2348 anchor):

1. RN minor 출시 → `node_modules/@react-native/codegen` 의 새 버전을
   `references/react-native-codegen/lib` 로 갱신
2. `bun scripts/generate-codegen-golden.mjs` 로 골든 재생성
3. `zig build test` 로 byte-diff 회귀 detect
4. 깨진 spec 의 패턴을 schema_builder / emitter 에 추가
