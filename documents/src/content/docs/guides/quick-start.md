---
title: 빠른 시작
description: ZNTC를 사용하여 TypeScript를 빠르게 변환해봅니다.
---

## 단일 파일 트랜스파일

```bash
# stdout 출력
zntc hello.ts

# 파일로 출력
zntc hello.ts -o hello.js
```

## 디렉토리 트랜스파일

```bash
zntc src/ --outdir dist/
```

## 번들링

```bash
# 단일 번들
zntc --bundle src/index.ts -o dist/bundle.js

# 코드 스플리팅
zntc --bundle src/index.ts --splitting --outdir dist/

# 라이브러리 빌드 (모듈 구조 유지)
zntc --bundle src/index.ts --preserve-modules --outdir dist/
```

## Minify

```bash
zntc --bundle src/index.ts -o dist/bundle.js --minify
```

## 소스맵

```bash
zntc --bundle src/index.ts -o dist/bundle.js --sourcemap
```

## Watch 모드

```bash
zntc --bundle src/index.ts -o dist/bundle.js --watch
```

## Dev Server

```bash
# 정적 파일 서빙
zntc --serve

# 번들 + HMR
zntc --serve --bundle src/index.ts
```

## 앱 빌더

Vite 스타일의 `index.html` 앱은 `zntc dev` / `zntc build`를 사용합니다.

```html
<!-- index.html -->
<link rel="stylesheet" href="/src/style.css" />
<script type="module" src="/src/main.ts"></script>
```

```bash
# HTML/env/public prepare + bundle + CSS HMR
zntc dev

# dist/에 빌드 산출물 쓰기
zntc build
```

앱 root에 `postcss.config.*`가 있으면 dev와 build 모두 CSS에 적용됩니다.
Tailwind v4는 `@tailwindcss/postcss`로 설정합니다.
