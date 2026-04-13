---
title: 번들링
description: ZTS의 번들링 기능을 자세히 알아봅니다.
---

## 기본 번들링

```bash
zts --bundle entry.ts -o bundle.js
```

## 출력 디렉토리

```bash
zts --bundle entry.ts --outdir dist/
```

## 코드 스플리팅

동적 import와 공유 모듈을 별도 청크로 분리합니다.

```bash
zts --bundle entry.ts --splitting --outdir dist/
```

## Preserve Modules

라이브러리 빌드 시 원본 디렉토리 구조를 유지합니다 (Rollup/Rolldown 호환).

```bash
zts --bundle src/index.ts --preserve-modules --outdir dist/
zts --bundle src/index.ts --preserve-modules --preserve-modules-root=src --outdir dist/
```

## 플랫폼

```bash
zts --bundle entry.ts --platform=browser   # 기본, IIFE 래핑
zts --bundle entry.ts --platform=node      # Node 내장 모듈 external
zts --bundle entry.ts --platform=react-native  # RN 프리셋
```

### browser (기본)

- `--format` 미지정 시 IIFE 자동 설정
- `process.env.NODE_ENV` → `"production"` 자동 define
- Node 내장 모듈 빈 모듈로 대체

### node

- Node 내장 모듈 + 서브패스 자동 external

### react-native

- `.native.*` / `.ios.*` / `.android.*` 확장자 자동 resolve
- `main-fields`: `react-native, browser, module, main`
- Flow 자동 활성화

## External

```bash
zts --bundle entry.ts --external react --external react-dom
```

## Alias

```bash
zts --bundle entry.ts --alias:react=preact/compat
```

## Loader

```bash
zts --bundle entry.ts --loader:.png=file --loader:.svg=dataurl
```

지원 로더: `js`, `ts`, `json`, `text`, `css`, `file`, `dataurl`, `binary`, `copy`, `empty`

## 파일명 패턴

```bash
zts --bundle entry.ts --outdir dist/ \
  --entry-names="[name]-[hash]" \
  --chunk-names="chunks/[name]-[hash]" \
  --asset-names="assets/[name]-[hash]"
```

## Banner / Footer

```bash
zts --bundle entry.ts -o bundle.js \
  --banner:js="/* MIT License */" \
  --footer:js="/* End of bundle */"
```

## Metafile

```bash
zts --bundle entry.ts -o bundle.js --metafile=meta.json
zts --bundle entry.ts -o bundle.js --analyze
```

## Minify

```bash
zts --bundle entry.ts -o bundle.js --minify  # 세 가지 모두

# 세분화 (esbuild 호환) — 개별 토글
zts --bundle entry.ts -o bundle.js --minify-whitespace
zts --bundle entry.ts -o bundle.js --minify-syntax
zts --bundle entry.ts -o bundle.js --minify-identifiers
```

## ES 타겟

```bash
# ES 버전 (es2015~esnext)
zts --bundle entry.ts -o bundle.js --target=es2020

# 엔진 타겟 — feature-level 다운레벨링
zts --bundle entry.ts -o bundle.js --target=chrome80,safari14
zts --bundle entry.ts -o bundle.js --target=node18
zts --bundle entry.ts -o bundle.js --target=hermes0.70
```

## 출력 포맷

```bash
zts --bundle entry.ts --format=esm    # ESM (기본)
zts --bundle entry.ts --format=cjs    # CommonJS
zts --bundle entry.ts --format=iife --global-name=MyLib  # IIFE
zts --bundle entry.ts --format=umd --global-name=MyLib   # UMD
zts --bundle entry.ts --format=amd                       # AMD
```

## Watch 모드

```bash
zts --bundle entry.ts -o bundle.js --watch
zts --bundle entry.ts -o bundle.js --watch-json  # NDJSON 이벤트 출력
```
