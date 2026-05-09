---
title: 소개
description: ZNTC가 무엇인지, 왜 만들었는지 알아봅니다.
---

## ZNTC란?

ZNTC는 **Zig Native Transpiler & Compiler**의 약자로, JavaScript/TypeScript/Flow를 네이티브 속도로 처리하는 트랜스파일 및 번들링 툴체인입니다. SWC, oxc 수준의 프로덕션 레벨 품질을 목표로 합니다.

## 주요 기능

- **TypeScript/JSX 트랜스파일**: 타입 스트리핑, enum 변환, decorator, JSX (classic/automatic)
- **번들링**: Tree-shaking, 코드 스플리팅, preserve-modules
- **React Native**: Metro 호환 번들링, Flow 스트리핑, Hermes 바이트코드 호환
- **플러그인**: Rollup/Vite 호환 플러그인 시스템 (C NAPI, in-process)
- **Dev Server**: HMR, 프록시, 정적 파일 서빙
- **WASM**: 브라우저에서 직접 트랜스파일 가능

## esbuild와의 비교

ZNTC는 esbuild의 CLI 옵션과 동작을 호환하면서도, Rollup/Rolldown 스타일의 플러그인 시스템을 제공합니다.

| 기능 | ZNTC | esbuild |
|------|-----|---------|
| 언어 | Zig | Go |
| TypeScript | O | O |
| Flow | O | X |
| React Native | O | X |
| preserve-modules | O | X |
| 플러그인 스타일 | Rollup 호환 | esbuild 자체 |
| WASM | O | O |
