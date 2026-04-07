---
title: React Native
description: ZTS를 React Native 프로젝트에서 사용하는 방법을 알아봅니다.
---

## 개요

ZTS는 `--platform=react-native` 프리셋으로 Metro 호환 RN 번들링을 지원합니다.

## 기본 사용법

```bash
zts --bundle index.js --platform=react-native -o bundle.js
```

## RN 서브 플랫폼

```bash
# iOS 빌드
zts --bundle index.js --platform=react-native --rn-platform=ios -o bundle.js

# Android 빌드
zts --bundle index.js --platform=react-native --rn-platform=android -o bundle.js
```

### 확장자 해석 순서

`--rn-platform=ios` 시:

```
.ios.tsx → .ios.ts → .ios.jsx → .ios.js →
.native.tsx → .native.ts → .native.jsx → .native.js →
.tsx → .ts → .jsx → .js → .json
```

## Flow 지원

`--platform=react-native`일 때 Flow가 자동 활성화됩니다. `@flow` pragma가 있는 파일에서 타입을 스트리핑합니다.

## main-fields

RN 플랫폼에서는 `package.json` 필드 순서가 자동으로 설정됩니다:

```
react-native → browser → module → main
```

## Hermes 호환

ZTS의 ES5 다운레벨링으로 Hermes 엔진과 호환되는 출력을 생성합니다.

```bash
zts --bundle index.js --platform=react-native --target=hermes0.70 -o bundle.js
```

## Watch + NDJSON

외부 도구 연동을 위한 NDJSON 이벤트 출력:

```bash
zts --bundle index.js --platform=react-native -o bundle.js --watch-json
```

```jsonl
{"type":"ready","files":2592,"bytes":123456}
{"type":"rebuild","success":true,"changed":["/src/app.tsx"],"modules":["/src/app.tsx"],"bytes":123456}
```
