# @zntc/react-native

**[English](./README.md)** · 한국어

> ZNTC React Native 플랫폼 레이어 — RN preset + Metro 호환 dev server + Reanimated worklets / Flow / Hermes.

[![npm](https://img.shields.io/npm/v/@zntc/react-native.svg)](https://www.npmjs.com/package/@zntc/react-native)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

`@zntc/react-native` 는 [ZNTC](https://github.com/ohah/zntc) 툴체인을 React Native 에 맞춥니다. 작은 사용자 입력을 Metro 호환 NAPI build 옵션으로 변환하고, Metro 호환 HMR dev server 를 제공하며, RN 전용 변환(Flow, Reanimated worklets, Hermes 타겟)을 연결합니다 — 모두 ZNTC 본체에 내장되어 **Babel 없이** 동작합니다.

제공 기능:

- **RN preset** — `buildRnBundleOptions(input)` / `bundleRn(input)` / `watchRn(input)`. RN 전용 build 옵션(Hermes/ES5 타겟, Flow, automatic-dev JSX, worklets, dev mode, Fast Refresh, polyfills, RN prelude banner)을 자동으로 적용합니다.
- **Metro 호환 dev server** — `serveRn(options)` / `buildRnDevServerOptions(input)`. per-platform watch, `/hot` 엔드포인트 위의 HMR bridge, terminal actions 를 한 번에 wiring 합니다.
- **Metro HMR adapter** — `createMetroHmrAdapter()` 가 RN runtime 의 HMRClient 인터페이스 호환 메시지(`hmr:update-start` / `hmr:update` / `hmr:update-done` / `hmr:reload` / `hmr:error` / `log`)를 송출합니다.
- **RN runtime** — `runtime/zntc-hmr-client.cjs`, RN runtime 용 HMRClient 호환 클라이언트.
- **Plugin factories** — `createAssetPlugin` / `createBabelPlugin` / `createCodegenPlugin` / `createRequireContextPlugin` / `createMetroResolveRequestPlugin`.
- **RN 상수 / helpers** — `RN_GLOBAL_IDENTIFIERS` / `tryResolve` / `resolveRnPolyfills`.

비범위(다른 곳에서 담당): iOS / Android 네이티브 빌드 오케스트레이션(`run-android` / `run-ios` / autolinking)은 `@react-native-community/cli` 영역입니다.

## 설치

```bash
bun add -D @zntc/react-native @zntc/core
# npm i -D @zntc/react-native @zntc/core
# pnpm add -D @zntc/react-native @zntc/core
```

일부 기능은 optional peer 패키지에 의존합니다 — 사용하는 환경에 필요한 것만 설치하세요:

```bash
bun add -D @babel/core @react-native/babel-preset metro-resolver react-native
```

dev server 의 reload / dev-menu broadcast 에는 `@react-native-community/cli-server-api` 가 필요합니다.

## 사용법

### 기존 React Native CLI 프로젝트에 부착

가장 간단한 경로는 scaffolder 입니다. 기존 RN CLI 앱의 `start` / `bundle:*` 스크립트를 ZNTC 로 교체합니다(Metro fallback 보존):

```bash
npx @zntc/init
```

자세한 절차는 [React Native 가이드](https://ohah.github.io/zntc/guides/react-native/)를 참고하세요.

### RN preset — `buildRnBundleOptions`

작은 RN 입력을 ZNTC NAPI build 옵션으로 변환한 뒤 build 를 실행합니다:

```ts
import { init, build } from '@zntc/core';
import { buildRnBundleOptions } from '@zntc/react-native';

await init();

const result = await build(
  buildRnBundleOptions({
    entry: '/abs/path/index.ts',
    projectRoot: '/abs/path',
    rnPlatform: 'ios', // 'ios' | 'android'
    dev: false,
    sourcemap: true,
  }),
);
```

`bundleRn(input)` 은 `build(buildRnBundleOptions(input))` 의 한 줄 단축형이고, `watchRn(input)` 은 watch 빌드를 시작합니다.

preset 은 RN 호환 기본값(Hermes/ES5 타겟, Flow, worklets, polyfills, RN prelude banner, asset loaders 등)을 자동 활성화합니다. dev 모드에서는 automatic-dev JSX, Fast Refresh, dev-mode runtime 까지 추가로 켭니다. `input.override` 로 사용자 override 를 얹을 수 있습니다(dictionary 는 deep-merge, array/primitive 는 replace).

### Metro 호환 dev server — `serveRn`

```ts
import { buildRnDevServerOptions, serveRn } from '@zntc/react-native';

const handle = await serveRn(
  buildRnDevServerOptions({
    bundle: {
      entry: '/abs/path/index.ts',
      projectRoot: '/abs/path',
      rnPlatform: 'ios',
      dev: true,
    },
    port: 8081,
    host: 'localhost',
  }),
);

// handle.url / handle.port — RN 앱을 이 서버에 연결
// await handle.stop(); — graceful 종료
```

`serveRn` 은 `@react-native-community/cli-server-api` 와 RN dev middleware 를 lazy 로드하고, per-platform watch 빌드를 돌리며, `/hot` 으로 HMR 을 제공하고, terminal actions(reload / dev menu)를 설정합니다. HMR 메시지는 Metro HMRClient 호환이라 표준 RN runtime 이 변경 없이 연결됩니다.

## Documentation

- Monorepo: <https://github.com/ohah/zntc>
- 문서: <https://ohah.github.io/zntc>
- React Native 가이드: <https://ohah.github.io/zntc/guides/react-native/>

## License

MIT
