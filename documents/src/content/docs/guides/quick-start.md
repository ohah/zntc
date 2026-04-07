---
title: 빠른 시작
description: ZTS를 사용하여 TypeScript를 빠르게 변환해봅니다.
---

## 단일 파일 트랜스파일

```bash
# stdout 출력
zts hello.ts

# 파일로 출력
zts hello.ts -o hello.js
```

## 디렉토리 트랜스파일

```bash
zts src/ --outdir dist/
```

## 번들링

```bash
# 단일 번들
zts --bundle src/index.ts -o dist/bundle.js

# 코드 스플리팅
zts --bundle src/index.ts --splitting --outdir dist/

# 라이브러리 빌드 (모듈 구조 유지)
zts --bundle src/index.ts --preserve-modules --outdir dist/
```

## Minify

```bash
zts --bundle src/index.ts -o dist/bundle.js --minify
```

## 소스맵

```bash
zts --bundle src/index.ts -o dist/bundle.js --sourcemap
```

## Watch 모드

```bash
zts --bundle src/index.ts -o dist/bundle.js --watch
```

## Dev Server

```bash
# 정적 파일 서빙
zts --serve

# 번들 + HMR
zts --serve --bundle src/index.ts
```
