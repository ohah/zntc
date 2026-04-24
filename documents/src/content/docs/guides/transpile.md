---
title: 트랜스파일
description: ZTS의 트랜스파일 기능을 자세히 알아봅니다.
---

## 기본 사용법

```bash
zts input.ts              # stdout으로 출력
zts input.ts -o output.js # 파일로 출력
zts src/ --outdir dist/   # 디렉토리 재귀 변환
echo "const x: number = 1" | zts -  # stdin 입력
```

## 지원하는 변환

### TypeScript

- 타입 어노테이션 제거
- 인터페이스/타입 선언 제거
- enum → 객체 + IIFE 변환
- namespace 변환
- `as` / `satisfies` 표현식

### JSX

```bash
# Classic (React.createElement)
zts --jsx=classic app.tsx

# Automatic (react/jsx-runtime)
zts --jsx=automatic app.tsx

# 개발 모드 (jsxDEV + source info)
zts --jsx=automatic-dev app.tsx

# 커스텀 factory
zts --jsx-factory=h --jsx-fragment=Fragment app.tsx
```

### Decorator

```bash
# Legacy (experimentalDecorators)
zts --experimental-decorators app.ts

# Class field를 constructor로 이동
zts --use-define-for-class-fields=false app.ts
```

### Flow

```bash
# @flow pragma 자동 감지
zts --flow app.js
```

### Import attributes (ES2024)

`with { type: "json" }` 구문을 모든 import/export 경로에서 라운드트립으로 보존합니다.
구버전 `assert` 는 static import 에 한해 `with` 로 자동 변환 (Node 20+ 가 `assert` 를 deprecate).

```ts
// static
import data from "./data.json" with { type: "json" };

// dynamic — 두 번째 인자도 그대로 보존
const mod = await import("./data.json", { with: { type: "json" } });

// re-export
export { default as data } from "./data.json" with { type: "json" };
export * from "./data.json" with { type: "json" };
export * as ns from "./data.json" with { type: "json" };
```

> 로컬 JSON import 는 확장자 기반으로 이미 번들에 인라인됩니다. `with { type }` 은 번들 산출물을 ESM 으로 Node 런타임에 흘려보낼 때, 또는 JSON 모듈 스펙에 호환되는 소스 생성이 필요할 때 유용합니다.

## 출력 옵션

### 모듈 포맷

```bash
zts --format=esm app.ts   # ESM (기본)
zts --format=cjs app.ts   # CommonJS
zts --format=iife app.ts  # 즉시 실행 함수
zts --format=umd app.ts   # UMD (브라우저/Node 양립)
zts --format=amd app.ts   # AMD (RequireJS)
```

### ES 타겟 / 엔진 타겟

```bash
# ES 버전 타겟 — es2015 ~ esnext
zts --target=es2020 app.ts

# 엔진 버전 타겟 — feature-level 다운레벨링
zts --target=chrome80,safari14 app.ts
zts --target=node18 app.ts
zts --target=hermes0.70 app.ts   # React Native (Hermes)
```

엔진 버전 타겟은 각 엔진이 지원하는 기능 표(`compat-table`)에 맞춰 필요한 변환만 수행합니다.

### Minify

```bash
zts --minify app.ts  # 세 가지 모두

# 세분화 (esbuild 호환)
zts --minify-whitespace app.ts    # 공백·세미콜론·줄바꿈 (디버깅 가능)
zts --minify-syntax app.ts        # true→!0, 괄호 제거, constant folding, 미참조 class expression name 제거
zts --minify-identifiers app.ts   # 지역 변수명 단축
```

조합 가능 — 예: 개발용 빌드에 `--minify-whitespace`만 켜서 디버그 가능한 작은 출력을 얻을 수 있습니다.

### 소스맵

```bash
zts --sourcemap app.ts -o app.js
# → app.js + app.js.map 생성
```

### 따옴표 스타일

```bash
zts --quotes=single app.ts   # 작은따옴표
zts --quotes=double app.ts   # 큰따옴표 (기본)
zts --quotes=preserve app.ts # 원본 유지
```

### ASCII Only

```bash
zts --ascii-only app.ts  # non-ASCII → \uXXXX 이스케이프
```

## Define

```bash
zts --define:DEBUG=false --define:VERSION='"1.0.0"' app.ts
```

## Drop

```bash
zts --drop=console app.ts     # console.* 제거
zts --drop=debugger app.ts    # debugger 문 제거
```
