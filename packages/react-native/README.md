# @zts/react-native

ZTS 의 React Native platform layer (#2540).

## 역할

- **RN preset** — `buildRnBundleOptions(input)` / `bundleRn(input)` / `watchRn(input)`. RN-specific NAPI build 옵션 (target=es5, flow, jsx=automatic-dev, devMode, reactRefresh, polyfills, runBeforeMain, banner) 자동 적용.
- **Metro HMR adapter** — `createMetroHmrAdapter()` (`@zts/server.HmrChannel` 위 thin wrapper). RN runtime 의 HMRClient interface 호환 메시지 (`hmr:update-start` / `hmr:update` / `hmr:update-done` / `hmr:reload` / `hmr:error` / `log`) 송출.
- **RN runtime** — `runtime/zts-hmr-client.js` (Metro HMRClient 인터페이스 호환 RN runtime).
- **Plugin factories** — `createAssetPlugin` / `createBabelPlugin` / `createCodegenPlugin` / `createRequireContextPlugin` / `createMetroResolveRequestPlugin`.
- **RN 상수 / helpers** — `RN_GLOBAL_IDENTIFIERS` / `tryResolve` / `resolveRnPolyfills`.

## 비범위 (이 패키지가 안 함)

- HTTP server / dev-middleware / asset registry / Rozenite DevTools / open-stack-frame / symbolicate — RN-specific runtime 영역, 사용자 측 (예: bungae) 가 운영
- iOS / Android native build orchestration (run-android / run-ios / autolinking) — `@react-native-community/cli` 영역

## 설치

```bash
bun add -D @zts/react-native @zts/core
# 사용 환경에 따라 optional:
# bun add -D @babel/core @react-native/babel-preset metro-resolver react-native
```

## 사용 예

```ts
import { init, build } from '@zts/core';
import { buildRnBundleOptions } from '@zts/react-native';

await init();
const result = await build(
  buildRnBundleOptions({
    entry: '/abs/path/index.ts',
    projectRoot: '/abs/path',
    rnPlatform: 'ios',
    dev: false,
    sourcemap: true,
  }),
);
```

## 관련 epic

- #2539 — `@zts/web` + `@zts/server` 분리 (선행, 완료)
- #2540 — 본 패키지 신설
- #2538 — Zig 단일 dev server (후속)
