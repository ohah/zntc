---
title: Flow 지원
description: ZNTC 의 Flow 타입 스트리핑 — React Native 코어 호환, 활성화 방법, 지원 구문 목록.
---

ZNTC 는 Facebook Flow 타입 어노테이션을 직접 파싱하고 스트리핑합니다. React Native 코어와 다수의 Meta 라이브러리가 Flow 로 작성되어 있어, RN 번들링에서는 사실상 필수 기능입니다.

## 언제 사용하는가

- **React Native 앱 번들링** — RN 코어, `react-native`, `react-native-*` 패키지 다수가 Flow 사용. `--platform=react-native` 시 자동 활성화됩니다.
- **Meta 생태계 라이브러리** — Hermes 엔진은 Flow 를 네이티브 실행하지만, 다른 환경(Node, 브라우저, V8) 에서는 stripping 이 필요합니다.
- **Flow 만 쓰는 레거시 코드베이스** — Babel `@babel/preset-flow` 를 ZNTC 로 대체.

## 활성화 방법

세 가지 방식이 모두 동작합니다 (우선순위: pragma > 확장자 > CLI/config).

### `// @flow` pragma 자동 감지

```ts
// @flow
const x: number = 1;
```

파일 상단에 pragma 가 있으면 자동으로 Flow 모드로 파싱됩니다. 이 모드에서는 같은 파일 안에 TypeScript 구문이 섞여 있으면 에러입니다.

### `.js.flow` 확장자

```ts
// types.js.flow
export type User = { id: number; name: string };
```

`.js.flow` 확장자는 Flow 타입 정의 파일로 인식되어 자동으로 Flow 모드로 파싱됩니다 (TypeScript 의 `.d.ts` 와 유사).

### CLI / config

```bash
zntc --bundle entry.js --flow -o bundle.js
```

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  flow: true,
});
```

`--platform=react-native` 를 사용하면 `flow: true` 가 자동으로 켜집니다.

## 지원되는 구문

### 기본 타입 어노테이션

```ts
// @flow
const n: number = 1;
const s: ?string = null;          // nullable
const m: mixed = anything;
const arr: number[] = [1, 2, 3];
const arr2: Array<string> = ['a'];

function add(a: number, b: number): number {
  return a + b;
}
```

지원: `string`, `number`, `boolean`, `bool`, `mixed`, `empty`, `void`, `null`, `?Type` (nullable), `T[]`, `Array<T>`.

### 제네릭

```ts
// @flow
function identity<T>(x: T): T { return x; }
function map<T, U>(arr: T[], fn: (x: T) => U): U[] { /* ... */ }

class Box<T> {
  value: T;
  constructor(v: T) { this.value = v; }
}
```

### Union / Intersection

```ts
// @flow
type Result = 'ok' | 'error' | 'pending';
type WithMeta<T> = T & { meta: Meta };
```

### Variance

```ts
// @flow
type ReadOnly = { +name: string };   // covariant (읽기 전용)
type WriteOnly = { -name: string };  // contravariant (쓰기 전용)
```

### Type alias / Opaque type

```ts
// @flow
type Point = { x: number; y: number };

opaque type UserId = string;                      // 외부에서는 string 으로 못 봄
opaque type Email: string = string;               // supertype constraint — 외부에서는 string 호환
```

### Interface

```ts
// @flow
interface Comparable<T> {
  compareTo(other: T): number;
}

interface Sortable extends Comparable<Sortable> {
  sort(): void;
}
```

### Import / Export type

```ts
// @flow
import type { User } from './types';
import typeof UserClass from './User';

export type Result = { ok: boolean };
export type { User } from './types';
```

### Declare

```ts
// @flow
declare class Logger { log(msg: string): void }
declare function debug(msg: string): void;
declare var __DEV__: boolean;

declare module 'some-untyped-lib' {
  declare module.exports: { foo: () => void };
}

declare export function exported(): void;
```

### TypeCast

```ts
// @flow
const x = (value: string);              // 괄호 캐스트
const y = obj as User;                  // as 캐스트
```

### Exact object type

```ts
// @flow
type ExactUser = {| id: number, name: string |};   // 추가 필드 금지
```

### Predicate function

```ts
// @flow
function isString(x: mixed): boolean %checks {
  return typeof x === 'string';
}
```

### Comment 타입

```ts
// @flow
const x /*: number */ = 1;            // 인라인
/*::
type Internal = { secret: string };
*/
```

JS 호환성을 유지하면서 타입을 추가할 때 사용. ZNTC 는 두 형태 모두 인식하고 stripping 합니다.

## 미지원 구문

다음 구문은 Metro / RN 코어에서 사용되지 않아 아직 미지원입니다. 필요한 경우 [GitHub 이슈](https://github.com/ohah/zntc/issues) 에 사용 사례와 함께 요청해 주세요.

| 구문 | 도입 | 상태 |
|---|---|---|
| `component` 선언 | Flow 2023 | 미지원 |
| `hook` 선언 | Flow 2023 | 미지원 |
| `match` 표현식 | Flow 2024 | 미지원 |

## 검증

`react-native` 0.74 의 모든 `@flow` 파일(410 개) 에 대해 파싱 + 스트리핑이 통과합니다. 회귀 테스트로 영구 보존됩니다.

```bash
# 직접 검증해 보고 싶다면
git clone https://github.com/facebook/react-native
zntc --bundle react-native/Libraries/react-native/index.js --platform=react-native -o /tmp/rn.js
```

## React Native 와 함께 쓰기

`--platform=react-native` 는 Flow 외에도 다음을 자동으로 활성화합니다.

- 플랫폼 확장자 자동 시도 — `.ios.tsx`, `.ios.ts`, `.ios.jsx`, `.ios.js`, `.native.*`, ...
- `main-fields` 에 `react-native` prepend
- Hermes 타겟 (`--target=hermes0.70`) 강제
- `process.env.NODE_ENV` define
- Metro 호환 block list (`__tests__/`, iOS/Android 빌드 폴더)

수동으로 세부 설정하려면:

```ts
defineConfig({
  flow: true,
  platform: "react-native",
  resolveExtensions: [
    ".ios.tsx", ".ios.ts", ".ios.jsx", ".ios.js",
    ".native.tsx", ".native.ts", ".native.jsx", ".native.js",
    ".tsx", ".ts", ".jsx", ".js",
  ],
  mainFields: ["react-native", "browser", "module", "main"],
});
```

자세한 RN 통합은 [React Native 가이드](/zntc/guides/react-native/) 를, Babel 기반 RN 프로젝트에서 옮겨오는 절차는 [Babel 마이그레이션](/zntc/guides/babel-migration/) 을 참고하세요.

## TypeScript 와 섞어 쓰기

같은 프로젝트에 Flow 파일과 TypeScript 파일이 공존하는 것은 지원합니다 — 파일 단위로 모드가 결정됩니다 (pragma / 확장자 / `--flow` 의 fallback 적용).

같은 **파일** 안에 두 문법을 섞는 것은 지원하지 않습니다 — TypeScript 컴파일러도 동일한 제약입니다.

## 더 읽을거리

- 컨트리뷰터용 설계 문서 — [`docs/FLOW.md`](https://github.com/ohah/zntc/blob/main/docs/FLOW.md): Flow 구현 의사결정, Metro 소스 분석, 미지원 구문 우선순위
- [React Native 가이드](/zntc/guides/react-native/) — RN 프로젝트 통합 전체 흐름
- [Babel 마이그레이션](/zntc/guides/babel-migration/) — 기존 Babel + Flow 설정에서 ZNTC 로 옮기기
