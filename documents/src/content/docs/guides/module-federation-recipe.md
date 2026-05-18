---
title: Module Federation 예제
description: ZNTC 로 빌드한 remote 를 표준 @module-federation/runtime host 가 그대로 소비하는 최소 실행 예제입니다.
---

ZNTC 로 빌드한 **remote** 를, 별도 ZNTC 런타임 없이 표준
`@module-federation/runtime` **host** 가 그대로 소비하는 최소 예제입니다.
ZNTC 는 표준 Module Federation 런타임 계약을 타깃하므로, host 쪽에는
ZNTC 의존성이 한 줄도 들어가지 않습니다.

개념·설정·한계 전반은 [Module Federation 가이드](/zntc/guides/module-federation/)를
먼저 보세요. 이 페이지는 그 가이드를 **돌려보는** 레시피입니다.

## 구성

```text
remote/
  zntc.config.json   # mf: name / exposes / shared
  src/Button.tsx     # 노출(expose)하는 React 컴포넌트 (react 는 shared)
  src/index.ts       # remote entry (컨테이너는 mf.exposes 에서 생성됨)
host.mjs             # 표준 @module-federation/runtime 으로 remote 소비
```

## 1. remote 설정

`remote/zntc.config.json`:

```json
{
  "mf": {
    "name": "remote_app",
    "exposes": { "./Button": "./src/Button.tsx" },
    "shared": { "react": { "singleton": true, "requiredVersion": "^19" } }
  }
}
```

- `exposes` — 다른 앱이 가져갈 수 있게 노출할 모듈. `{ 공개경로: 소스경로 }`.
- `shared` — 번들에 포함하지 않고 host 가 제공하는 단일 인스턴스를
  공유할 의존성. React 처럼 인스턴스가 갈리면 hooks 가 깨지는
  라이브러리에 필수. `singleton` + `requiredVersion` 으로 버전 계약을 건다.

## 2. 노출할 컴포넌트

`remote/src/Button.tsx` — `react` 는 `mf.shared` 로 선언했으므로 번들에
포함되지 않고 host 의 단일 인스턴스를 공유합니다.

```tsx
import { useState, createElement } from 'react';

export default function Button() {
  const [count, setCount] = useState(0);
  return createElement(
    'button',
    { onClick: () => setCount(count + 1) },
    `remote Button — count: ${count}`,
  );
}
```

`remote/src/index.ts` 는 entry sentinel 역할만 합니다 — 컨테이너
(remoteEntry)는 ZNTC 가 `mf.exposes` 에서 생성합니다.

```ts
export const name = 'remote_app';
```

## 3. remote 빌드

remote 는 앱이 아니라 **MF remote 컨테이너**이므로 app 모드
`zntc build` 가 아닌 core 모드로 빌드합니다.

```sh
cd remote
zntc --bundle src/index.ts --outdir dist --format=iife \
  --public-path=file://$PWD/dist/
```

산출물: 컨테이너(remoteEntry) + `mf-manifest.json` + content-hash 청크.

## 4. 표준 host 로 소비

`host.mjs` — ZNTC 의존성 없이 표준 `@module-federation/runtime` 의
`init` / `loadRemote` 만 사용합니다.

```js
import * as hostReact from 'react';
import * as mfNs from '@module-federation/runtime';

// @module-federation/runtime 은 CJS — namespace import 후 default 추출
const { init, loadRemote } = mfNs.default ?? mfNs;

// host 가 자기 react 를 shared 로 등록 → remote 의 shared:{react} 가
// 이 단일 인스턴스를 공유(hooks 동작 조건).
init({
  name: 'host_app',
  remotes: [{ name: 'remote_app', entry: 'http://localhost:PORT/index.js' }],
  shared: {
    react: {
      version: '19.0.0',
      lib: () => hostReact,
      shareConfig: { singleton: true, requiredVersion: '^19' },
    },
  },
});

// 표준 loadRemote 로 ZNTC remote 컴포넌트를 동적으로 가져온다.
const mod = await loadRemote('remote_app/Button');
const Button = mod.default ?? mod;
```

> Node 는 http import 를 지원하지 않으므로 이 예제는 remote **entry**
> 만 http 로 서빙하고 청크는 빌드 시 지정한 publicPath(`file://dist/`)로
> 로드하는 "entry=http / chunk=file://" 하이브리드를 씁니다. 브라우저
> host 면 양쪽 다 http 입니다.

## 5. 실행

리포지토리 루트에서 한 번 설치한 뒤:

```sh
bun install
bun run --cwd examples/module-federation demo
```

`demo` 는 (1) ZNTC 로 `remote/` 를 빌드하고 (2) `host.mjs` 를 실행합니다.
개별 실행:

```sh
bun run --cwd examples/module-federation build   # zntc → remote/dist
bun run --cwd examples/module-federation start   # host.mjs
```

기대 출력:

```text
component: true / shared React singleton: true
element type === Button: true
OK — zntc remote 컴포넌트를 표준 host 가 소비, react 단일 인스턴스 공유
```

## 무엇을 확인하나

- `host.mjs` 에 **ZNTC 의존성이 전혀 없다** — 표준
  `@module-federation/runtime` 만으로 동작.
- `loadRemote('remote_app/Button')` 가 ZNTC 가 emit 한 컨테이너에서
  컴포넌트를 가져온다.
- remote 의 `react` 가 host 가 등록한 `react` 와 **동일 인스턴스**다
  (`shared` singleton 성립 — hooks 가 깨지지 않는 조건).

전체 코드는
[`examples/module-federation`](https://github.com/ohah/zntc/tree/main/examples/module-federation)
에 있습니다.

## 관련 문서

- [Module Federation 가이드](/zntc/guides/module-federation/) — 설정·동작
  원리·빌드타임 계약 검증·한계.
- [플러그인 레시피](/zntc/guides/plugin-recipes/) — CSS / PostCSS / SVG
  등 자주 쓰는 plugin 패턴.
