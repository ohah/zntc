---
title: 소개
description: ZNTC가 무엇인지, 왜 만들었는지 알아봅니다.
---

## ZNTC란?

ZNTC는 **Zig Native Transpiler & Compiler**의 약자로, JavaScript/TypeScript/Flow를 네이티브 속도로 처리하는 트랜스파일 및 번들링 툴체인입니다.

## 주요 기능

- **TypeScript/JSX 트랜스파일** — 타입 스트리핑, enum 변환, decorator, JSX (classic/automatic). [트랜스파일 개요](/zntc/guides/transpile/) · [네이티브 트랜스폼](/zntc/guides/native-transforms/)
- **번들링** — Tree-shaking, 코드 스플리팅, preserve-modules. [번들링 개요](/zntc/guides/bundling/) · [트리쉐이킹](/zntc/guides/tree-shaking/) · [manualChunks](/zntc/guides/manual-chunks/)
- **React Native** — Metro 호환 번들링, Flow 스트리핑, Hermes 바이트코드 호환. [React Native 가이드](/zntc/guides/react-native/) · [Expo](/zntc/guides/react-native-expo/)
- **플러그인** — Rollup/Vite 호환 플러그인 시스템 (C NAPI, in-process). [플러그인 가이드](/zntc/guides/plugins/) · [Vite 어댑터](/zntc/guides/vite/)
- **Dev Server** — HMR, 프록시, 정적 파일 서빙, SSE. [Dev Server 가이드](/zntc/guides/dev-server/)
- **WASM** — 브라우저 / Edge / WASI 에서 직접 트랜스파일 + 번들. [설치 가이드의 WASM 섹션](/zntc/guides/installation/)

## Babel 없이 1st-party 지원

다른 번들러에서 Babel 플러그인 / preset 으로 따로 묶어야 했던 변환들이 ZNTC 본체에 내장되어 있습니다. `@babel/core` 의존성 없이 옵션 한 줄로 켜집니다.

- **styled-components** — `compiler.styledComponents` (`babel-plugin-styled-components` 대응)
- **emotion** — `compiler.emotion` (`@emotion/babel-plugin` 대응)
- **Reanimated worklets** — `"worklet"` 디렉티브 자동 처리 (`react-native-worklets/plugin` 대응, RN 플랫폼에서 자동 활성)
- **Flow** — 타입 어노테이션을 파서에서 직접 처리 (`@babel/preset-flow` 대응, RN 플랫폼에서 자동 활성)

자세한 사용법은 [네이티브 트랜스폼 가이드](/zntc/guides/native-transforms/) 를 참조하세요.
