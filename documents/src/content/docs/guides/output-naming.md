---
title: 출력 파일명 패턴
description: entry / chunk / asset / CSS 파일명 규칙과 동작 원리.
---

## 옵션

빌드 결과 파일명을 패턴으로 제어할 수 있습니다.

| 옵션 | 적용 대상 | 기본값 |
|---|---|---|
| `entryNames` | 사용자 명시 entry chunk | `[dir]/[name]` |
| `chunkNames` | 동적 import / manual / common chunk | `[name]-[hash]` |
| `cssNames` | entry CSS chunk | `[dir]/[name]` |
| `assetNames` | asset (이미지, 폰트 등) | `[name]-[hash]` |

## 패턴 토큰

| 토큰 | 치환 결과 |
|---|---|
| `[name]` | entry 모듈의 basename (확장자 제외) |
| `[hash]` | content hash 8자리 hex |
| `[dir]` | entry 와 entry_dir 의 상대 dir |

`[dir]` 토큰의 `entry_dir` 은 모든 entry 의 dirname 의 longest common parent (esbuild `outbase` 동치).

## 정적 vs 동적 entry 구분

| Chunk 종류 | 적용 옵션 |
|---|---|
| 사용자가 `entryPoints` 로 명시한 entry | `entryNames` |
| `import()` 로 생성된 동적 chunk | `chunkNames` |
| `manualChunks` 결과 chunk | `chunkNames` |
| 공유 모듈 추출된 common chunk | `chunkNames` |

Rollup `entryFileNames` / `chunkFileNames` 분리 정책과 동일.

## 폴더 분리 예시

```ts
// zntc.config.ts
export default {
  entryPoints: ['src/main.ts'],
  splitting: true,
  entryNames: 'static/[name]',
  chunkNames: 'chunks/[name]-[hash]',
};
```

빌드 결과:
```
dist/
  static/main.js          ← entryNames 적용
  chunks/lazy-a1b2c3d4.js ← chunkNames 적용 (import('./lazy') 결과)
```

entry chunk 안의 동적 import 는 자동으로 상대 경로 계산:
```js
// dist/static/main.js
import("../chunks/lazy-a1b2c3d4.js")
```

런타임에서 Node 가 `dist/chunks/lazy-a1b2c3d4.js` 를 정확히 해석.

## 옛 평면 동작 (마이그레이션)

새 default `[dir]/[name]` 이전 동작이 필요하면 명시:

```ts
export default {
  entryNames: '[name]',
  cssNames: '[name]',
};
```

또는 CLI:
```bash
zntc --entry-names='[name]' --css-names='[name]' src/index.ts
```

## 알려진 한계

- **`entryNames` ↔ `cssNames` 비대칭**: 사용자가 entry 와 CSS 를 *다른 dir* 로 강제 (`entryNames: '[name]'` + `cssNames: 'assets/[name]'`) 하면 동적 chunk 의 `<link>` href 가 basename 만 사용해 cascade 깨짐. 기본값처럼 둘 다 같은 dir 패턴 권장.
- **`chunkNames` 의 `[dir]` 미지원**: dynamic / manual / common chunk 는 entry-relative dir 정보가 없어 `[dir]` 토큰 치환 시 빈 문자열로 처리 (toleranet).
- **`outbase` 명시 override**: 현재 `entry_dir` 은 entry_points 로부터 자동 추론만. `outbase` 옵션이 있어도 silent 무시 (issue 추적 중).

## 동적 entry 정책 (Rollup parity)

`import()` 로 생성되는 chunk 는 `entry_point.is_dynamic = true` 로 표시되어 `chunkNames` 패턴 적용. 즉:

```ts
// src/main.ts
import('./lazy');  // → chunks/lazy-<hash>.js (chunkNames 적용)

// src/lazy.ts
export const x = 1;
```

`entryNames` 가 `'static/[name]'` 이고 사용자가 `entryPoints: ['src/main.ts']` 명시했어도 `lazy` 는 *사용자 명시 entry 가 아님* → `chunkNames` 적용.

## Plugin renderChunk 와의 정합

`onRenderChunk({ filter, callback })` 의 `callback` 이 받는 두 번째 인자(`chunk_name`)는 *실제 파일명의 stem (확장자 제외)* 과 동일합니다. preserve_modules / explicit fileName 모드에서도 정합 보장 — visualizer / manifest 플러그인에서 안심하고 사용할 수 있습니다.

```ts
zntc.build({
  plugins: [{
    name: 'manifest',
    setup(build) {
      build.onRenderChunk({ filter: /.*/ }, ({ chunk }) => {
        // chunk === path 의 stem
        manifest[chunk] = ...;
        return null;
      });
    },
  }],
});
```
