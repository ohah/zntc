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

## 출력 옵션

### 모듈 포맷

```bash
zts --format=esm app.ts   # ESM (기본)
zts --format=cjs app.ts   # CommonJS
```

### Minify

```bash
zts --minify app.ts  # whitespace + identifiers + syntax 전부
```

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
