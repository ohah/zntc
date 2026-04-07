---
title: React Native
description: Learn how to use ZTS with React Native projects.
---

## Overview

ZTS supports Metro-compatible React Native bundling via the `--platform=react-native` preset.

## Basic Usage

```bash
zts --bundle index.js --platform=react-native -o bundle.js
```

## RN Sub-platform

```bash
# iOS build
zts --bundle index.js --platform=react-native --rn-platform=ios -o bundle.js

# Android build
zts --bundle index.js --platform=react-native --rn-platform=android -o bundle.js
```

### Extension Resolution Order

With `--rn-platform=ios`:

```
.ios.tsx -> .ios.ts -> .ios.jsx -> .ios.js ->
.native.tsx -> .native.ts -> .native.jsx -> .native.js ->
.tsx -> .ts -> .jsx -> .js -> .json
```

## Flow Support

Flow is automatically enabled when `--platform=react-native` is set. Type annotations are stripped from files containing the `@flow` pragma.

## main-fields

On the RN platform, `package.json` field resolution order is automatically configured:

```
react-native -> browser -> module -> main
```

## Hermes Compatibility

ZTS ES5 downleveling produces output compatible with the Hermes engine.

```bash
zts --bundle index.js --platform=react-native --target=hermes0.70 -o bundle.js
```

## Watch + NDJSON

NDJSON event output for integration with external tools:

```bash
zts --bundle index.js --platform=react-native -o bundle.js --watch-json
```

```jsonl
{"type":"ready","files":2592,"bytes":123456}
{"type":"rebuild","success":true,"changed":["/src/app.tsx"],"modules":["/src/app.tsx"],"bytes":123456}
```
