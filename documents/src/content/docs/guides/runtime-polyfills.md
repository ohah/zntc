---
title: 런타임 폴리필 (core-js)
description: ZNTC 의 core-js 런타임 API 폴리필 — auto/usage/entry 모드, --runtime-polyfills / --runtime-target / --core-js, runtimePolyfills 설정 객체, @babel/preset-env useBuiltIns 대응.
---

`--target` (또는 `browserslist`) 은 **문법**을 낮춥니다 — arrow function → function expression, `async`/`await` → state machine, class fields 등. 하지만 `Promise`, `Map`, `Set`, `Object.values`, `String.prototype.replaceAll`, `Array.prototype.at`, `Object.hasOwn`, `structuredClone` 같은 건 **런타임 API** 라 문법 변환만으로는 안 됩니다 — 옛 엔진엔 그 함수/객체 자체가 없으니까요. 이걸 메우는 게 `--runtime-polyfills` 입니다 (`@babel/preset-env` 의 `useBuiltIns` + `core-js` 와 같은 역할).

## 사용법

`core-js` 와 `core-js-compat` 은 optional dependency 입니다 — 폴리필을 켤 프로젝트에서만 설치하면 됩니다.

```bash
bun add core-js core-js-compat   # 또는 npm i core-js core-js-compat
```

```bash
zntc --bundle entry.ts -o bundle.js \
  --target=es5 \
  --runtime-polyfills=auto \
  --runtime-target="ios_saf 12" \
  --core-js=3.49
```

번들 그래프에서 감지된 API 중 `--runtime-target` 이 지원하지 않는 것만 골라, 필요한 `core-js/modules/*.js` 가 엔트리보다 **먼저** 실행되도록 prelude 로 넣습니다.

| CLI 플래그 | 설명 |
|---|---|
| `--runtime-polyfills=off\|auto\|usage\|entry` | 폴리필 주입 모드 (기본 `off`) |
| `--runtime-target=<query>` | `core-js-compat` 에 넘길 Browserslist query. 반복 가능 (`--runtime-target="ios_saf 12" --runtime-target="safari 12"`) |
| `--core-js=<version>` | `core-js-compat` 계산에 쓸 core-js 버전. 생략 시 설치된 `core-js/package.json` 버전 |

## 모드

| 모드 | 동작 | `@babel/preset-env` 대응 |
|---|---|---|
| `off` | 기본값. `core-js-compat` 로드·graph collector 둘 다 실행 안 함 | `useBuiltIns: false` |
| `auto` | 번들 그래프에서 **실제로 쓰인** API 중 타겟이 지원 안 하는 `core-js` 모듈만 주입 | `useBuiltIns: "usage"` |
| `usage` | `auto` 의 alias | `useBuiltIns: "usage"` |
| `entry` | 사용 여부와 무관하게 타겟에 필요한 `core-js` ES/Web 모듈 **전체**를 엔트리 prelude 로 주입 | `useBuiltIns: "entry"` (단, ZNTC 는 엔트리에 `import "core-js"` 를 쓸 필요 없이 플래그만으로) |

`auto`/`usage` 는 JS wrapper 의 Babel pre-scan 이 아니라 resolve / package exports / alias / plugin load·transform 까지 끝난 **native graph AST** 기준으로 동작합니다 — dependency 내부 코드도 감지 대상이고, 코드 스플리팅을 켜도 runtime prelude 는 user entry 보다 먼저 실행되도록 graph root 로 포함됩니다.

감지는 정적 AST 기반이라 (a) 전역을 가리는 local binding/import 는 제외하고 (b) `obj["replaceAll"]()` 같은 동적 computed access 는 추론하지 않습니다. 그런 코드는 `include` 로 강제 주입하거나 `entry` 모드를 씁니다.

## 설정 객체 (`runtimePolyfills`)

config 파일 / JS API 에서는 object 형태로 세밀하게 제어합니다.

```ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  entryPoints: ["src/index.ts"],
  bundle: true,
  target: "es5",
  runtimePolyfills: {
    mode: "auto",
    targets: ["safari 12", "ios_saf 12"],
    coreJs: "3.49",
    include: ["es.array.at"],
    exclude: ["web.url"],
  },
});
```

| 필드 | 타입 | 설명 |
|---|---|---|
| `mode` | `"auto" \| "usage" \| "entry"` | 위 모드 표 참조 |
| `provider` | `"core-js"` | 현재는 `core-js` 만 |
| `targets` | `string \| string[]` | `core-js-compat` 에 넘길 Browserslist query (Rspack/SWC `env.targets` 와 같은 형식) |
| `coreJs` | `string` | core-js 버전 힌트. 생략 시 설치 버전 |
| `include` | `string[]` | 항상 주입할 모듈. `es.array.at` 또는 `core-js/modules/es.array.at.js` 형식 |
| `exclude` | `string[]` | target/usage 계산 뒤 최종 제거할 모듈 |
| `proposals` | `boolean` | `core-js-compat` 조회 시 proposals 포함 |

`runtimePolyfills: "auto"` (문자열) 은 `{ mode: "auto" }` 와 동일한 단축형입니다.

`targets` query 는 Browserslist 문법 그대로 — `ios_saf 12`, `safari 12`, `node 18` 처럼 명시적으로 쓰고, `ios12` / `node18` 같은 compact shorthand 나 `"iPhone 8"` 같은 physical device 이름은 쓰지 않습니다. React Native 의 기본 Hermes 타겟은 `--platform=react-native` 로 자동 선택되므로 `--runtime-target` 없이도 됩니다.

```ts
runtimePolyfills: {
  mode: "auto",
  targets: ["chrome >= 87", "edge >= 88", "firefox >= 78", "safari >= 14"],
}
```

## 실행 순서

runtime polyfill prelude 는 기존 수동 polyfill / entry hook 사이에 끼어듭니다.

```text
manual polyfills (`polyfills`) / inject roots  →  runtime core-js prelude  →  `runBeforeMain`  →  user entry
```

- `polyfills` — 번들 시작 시 즉시 실행할 모듈 (앱 코드보다 먼저 무조건 실행).
- `runBeforeMain` — entry 직전에 실행할 모듈 (환경 셋업용 — RN 의 `InitializeCore` 등). 번들 그래프에 포함되어 prelude 로 emit, runtime polyfill **다음** / user entry **직전**.

```ts
defineConfig({
  runBeforeMain: ["./src/setup-env.ts"],
});
```

## 디버깅

```bash
ZNTC_DEBUG=runtime_polyfills zntc --bundle entry.ts \
  --runtime-polyfills=auto \
  --runtime-target="safari 12" \
  --profile=graph --profile-level=detailed --profile-format=json
```

`runtime_polyfills` debug category 가 후보 계산 / graph usage 집계 / 최종 주입 목록을 찍고, `--profile=graph` 가 그래프 단계 타이밍을 보여줍니다.

## 함께 보기

- [번들러 개요 — ES 타겟](/zntc/guides/bundling/#es-타겟) — `--target` / `browserslist` 로 문법 다운레벨링
- [Babel 이관 (RN)](/zntc/guides/babel-migration/) — `@babel/preset-env` + `core-js` 설정을 ZNTC 로 옮기기
- [Transpile 옵션 — `runtimePolyfills`](/zntc/reference/options/) / [CLI 레퍼런스](/zntc/reference/cli/)
