---
title: 트랜스파일
description: ZNTC의 트랜스파일 기능을 자세히 알아봅니다.
---

## 기본 사용법

```bash
zntc input.ts              # stdout으로 출력
zntc input.ts -o output.js # 파일로 출력
zntc src/ --outdir dist/   # 디렉토리 재귀 변환
echo "const x: number = 1" | zntc -  # stdin 입력
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
zntc --jsx=classic app.tsx

# Automatic (react/jsx-runtime)
zntc --jsx=automatic app.tsx

# 개발 모드 (jsxDEV + source info)
zntc --jsx=automatic-dev app.tsx

# 커스텀 factory
zntc --jsx-factory=h --jsx-fragment=Fragment app.tsx
```

### Decorator

```bash
# Legacy (experimentalDecorators)
zntc --experimental-decorators app.ts

# Class field를 constructor로 이동
zntc --use-define-for-class-fields=false app.ts
```

### Flow

```bash
# @flow pragma 자동 감지
zntc --flow app.js
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
>
> **동작**: `with { type }` 은 라운드트립 메타데이터입니다. loader 선택은 오직 **확장자 기반**이며, attrs 값으로 loader 를 강제하거나 (`.txt` → JSON) 알 수 없는 type 에 에러를 내지 않습니다.

## 출력 옵션

### 모듈 포맷

```bash
zntc --format=esm app.ts   # ESM (기본)
zntc --format=cjs app.ts   # CommonJS
zntc --format=iife app.ts  # 즉시 실행 함수
zntc --format=umd app.ts   # UMD (브라우저/Node 양립)
zntc --format=amd app.ts   # AMD (RequireJS)
```

### ES 타겟 / 엔진 타겟

```bash
# ES 버전 타겟 — es2015 ~ esnext
zntc --target=es2020 app.ts

# 엔진 버전 타겟 — feature-level 다운레벨링
zntc --target=chrome80,safari14 app.ts
zntc --target=node18 app.ts
zntc --target=hermes0.70 app.ts   # React Native (Hermes)
```

엔진 버전 타겟은 각 엔진이 지원하는 기능 표(`compat-table`)에 맞춰 필요한 변환만 수행합니다.

### Minify

```bash
zntc --minify app.ts  # 세 가지 모두

# 세분화 (esbuild 호환)
zntc --minify-whitespace app.ts    # 공백·세미콜론·줄바꿈 (디버깅 가능)
zntc --minify-syntax app.ts        # true→!0, 괄호 제거, constant folding, 미참조 class expression name 제거
zntc --minify-identifiers app.ts   # 지역 변수명 단축
```

조합 가능 — 예: 개발용 빌드에 `--minify-whitespace`만 켜서 디버그 가능한 작은 출력을 얻을 수 있습니다.

### 소스맵

```bash
zntc --sourcemap app.ts -o app.js
# → app.js + app.js.map 생성
```

### 따옴표 스타일

```bash
zntc --quotes=single app.ts   # 작은따옴표
zntc --quotes=double app.ts   # 큰따옴표 (기본)
zntc --quotes=preserve app.ts # 원본 유지
```

### ASCII Only

```bash
zntc --ascii-only app.ts  # non-ASCII → \uXXXX 이스케이프
```

## Define

```bash
zntc --define:DEBUG=false --define:VERSION='"1.0.0"' app.ts
```

값은 **JavaScript 리터럴** 이어야 합니다. 큰따옴표 빠뜨리는 함정에 주의.

```bash
# ✗ 틀림 — admin 이 식별자로 처리되어 의도와 다른 코드 생성
zntc --define:USERNAME=admin app.ts

# ✓ 맞음 — 큰따옴표 포함해 문자열 리터럴
zntc --define:USERNAME='"admin"' app.ts

# ✓ 숫자 / 불리언 / null 은 그대로 리터럴
zntc --define:DEBUG=false --define:MAX=100 --define:USER=null app.ts

# ✓ 객체 / 배열도 JSON 리터럴이면 OK
zntc --define:ENV='{"mode":"prod"}' app.ts
```

쉘 quoting 함정 — bash/zsh 에서 큰따옴표를 보존하려면 작은따옴표로 감싸야 합니다.

## Drop

세 가지 제거 옵션이 독립적으로 동작 — 동시에 사용 가능합니다.

```bash
# console.* 호출 제거
zntc --drop=console app.ts

# debugger 문 제거
zntc --drop=debugger app.ts

# labeled block 통째로 제거 — 쉼표로 여러 라벨 지정
zntc --drop-labels=DEV,TEST app.ts

# 셋 다 동시에
zntc --drop=console --drop=debugger --drop-labels=DEV,TEST app.ts
```

`--drop-labels` 예시:

```ts
// 원본
DEV: {
  console.log("debug only");
  attachDevtools();
}

// --drop-labels=DEV → 위 블록 전체가 출력에서 사라짐
```

production 빌드 전용 디버그 코드를 라벨로 감싸면 한 번에 제거할 수 있습니다.
