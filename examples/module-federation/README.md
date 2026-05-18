# Module Federation 예제 (zntc remote ↔ 표준 host)

zntc 로 빌드한 **remote** 를, 별도 zntc 런타임 없이 표준
`@module-federation/runtime` **host** 가 그대로 소비하는 최소 예제입니다
(이 예제가 보여주는 방향). zntc 는 표준 Module Federation 런타임 계약을
타깃하므로, 더 넓은 interop 범위·원리·한계는 문서 사이트의 Module
Federation 가이드를 참고하세요.

## 구성

```
remote/
  zntc.config.json   # mf: name / exposes / shared
  src/Button.tsx      # 노출(expose)하는 React 컴포넌트 (react 는 shared)
  src/index.ts        # remote entry (컨테이너는 mf.exposes 에서 생성)
host.mjs              # 표준 @module-federation/runtime 으로 remote 소비
```

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

- `exposes` — 다른 앱이 가져갈 수 있게 노출할 모듈
- `shared` — 번들에 포함하지 않고 host 가 제공하는 단일 인스턴스를
  공유할 의존성. `singleton` + `requiredVersion` 으로 버전 계약을 건다
  (React 처럼 인스턴스가 갈리면 안 되는 라이브러리에 필수).

## 실행

리포지토리 루트에서 한 번 설치한 뒤:

```sh
bun install
bun run --cwd examples/module-federation demo
```

`demo` 는 (1) zntc 로 `remote/` 를 빌드하고 (2) `host.mjs` 를 실행합니다.
빌드는 앱이 아니라 **MF remote 컨테이너**라서 app 모드 `zntc build` 가
아닌 core 모드 `zntc --bundle … --format=iife` 를 씁니다(다른 예제는
app 모드). 개별 실행:

```sh
bun run --cwd examples/module-federation build   # zntc → remote/dist
bun run --cwd examples/module-federation start   # host.mjs
```

기대 출력:

```
component: true / shared React singleton: true
element type === Button: true
OK — zntc remote 컴포넌트를 표준 host 가 소비, react 단일 인스턴스 공유
```

## 무엇을 보여주나

- `host.mjs` 에 **zntc 의존성이 전혀 없다** — 표준
  `@module-federation/runtime` 의 `init` / `loadRemote` 만 쓴다.
- `loadRemote('remote_app/Button')` 가 zntc 가 emit 한 컨테이너에서
  컴포넌트를 가져온다.
- remote 의 `react` 가 host 가 등록한 `react` 와 **동일 인스턴스**다
  (`shared` singleton 성립 — hooks 가 깨지지 않는 조건).

`host.mjs` 는 데모 목적상 react-dom 없이 컴포넌트/싱글톤만 확인한다.
브라우저 host 면 가져온 컴포넌트를 그대로 `react-dom` 으로 렌더하면 된다.
remote **entry** 만 http 로 서빙하고 청크는 entry 의 publicPath(빌드 시
`file://dist/`)로 로드된다 — Node 는 http import 미지원이라 "entry=http /
chunk=file://" 하이브리드가 표준 Node interop 패턴(브라우저면 양쪽 http).

> 개념 설명(원리·설정·한계)은 문서 사이트의 Module Federation 가이드를
> 참고하세요.
