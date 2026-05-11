---
title: Vite
description: 기존 Vite 프로젝트에서 ZNTC 로 esbuild transform 을 대체하는 방법입니다.
---

ZNTC 는 `@zntc/vite-plugin` 으로 Vite 의 esbuild transform 자리에 들어갑니다. Vite 의 dev server / HMR / plugin 생태계는 그대로 사용하시고, `.ts` / `.tsx` / `.jsx` 변환만 ZNTC 가 담당합니다.

## 프로젝트 구조

```text
my-vite-app/
├── index.html
├── vite.config.ts          # @zntc/vite-plugin 등록
├── src/
│   ├── main.tsx
│   └── App.tsx
└── package.json
```

## 자동 적용 (`zntc-init vite`)

`vite` 가 dependency 에 있는 기존 프로젝트에 ZNTC 를 얹는 가장 빠른 방법입니다. `vite` 가 없으면 `zntc-init web` 으로 standalone scaffold 를 사용하세요 ([Web (standalone)](/zntc/guides/web-starter/)).

```bash
npx @zntc/init vite
```

수행 작업:

- `package.json` 에 `@zntc/core`, `@zntc/vite-plugin` 개발 의존성을 추가합니다.
- `vite.config.ts` (또는 `.mts` / `.js` / `.mjs`) 가 없으면 기본 config 를 생성합니다.
- 기존 config 가 있으면 manual patch 안내를 출력합니다. `--force` 로 덮어쓰기 가능.

기본 생성 config:

```ts
// vite.config.ts
import { defineConfig } from "vite";
import { zntc } from "@zntc/vite-plugin";

export default defineConfig({
  plugins: [zntc()],
  esbuild: false,
});
```

## 수동 적용

기존 `vite.config.ts` 에 직접 끼우려면 다음 두 곳을 수정합니다.

```ts
import { defineConfig } from "vite";
import { zntc } from "@zntc/vite-plugin";

export default defineConfig({
  plugins: [
    zntc(), // 기존 plugins 배열 앞쪽 (esbuild 자리)
    // ...기존 plugins
  ],
  esbuild: false, // Vite 의 esbuild transform 비활성
});
```

`esbuild: false` 가 필수입니다 — Vite 가 esbuild 로 `.ts`/`.tsx` 를 transform 하면 ZNTC 와 중복 처리되어 출력이 어긋날 수 있습니다.

## 명령

Vite 의 기존 CLI 를 그대로 사용합니다.

```bash
bun vite           # dev server (Vite HMR)
bun vite build     # 프로덕션 번들
bun vite preview   # 빌드 결과 미리보기
```

## Vite vs ZNTC 자체 dev server

- `bun vite` — Vite dev server + ZNTC transform. Vite 의 HMR / plugin 생태계 그대로 사용.
- `zntc dev <root>` — ZNTC 자체 dev server. Vite 없이 동작. ZNTC plugin API 만 사용 가능 ([Dev Server](/zntc/guides/dev-server/) 참조).

같은 프로젝트에서 둘 중 적절한 것을 선택해 사용하시면 됩니다. 일반적으로 기존 Vite 생태계를 이미 사용 중이면 Vite + `@zntc/vite-plugin` 조합이 자연스럽습니다.

## 동작 요약

`@zntc/vite-plugin` 의 `zntc()` 는 다음 Vite hook 에 attach 됩니다.

- `resolveId` / `load` — 사용자 ZNTC plugin (`zntc.config.ts`) 의 resolve / load 훅을 Vite 쪽으로 미러링.
- `transform` — `.ts` / `.tsx` / `.jsx` / `.mts` / `.cts` / `.flow.js` 를 ZNTC 로 변환. source map 객체 반환 (Vite 4+ 호환).
- `renderChunk` / `generateBundle` — 사용자 plugin 의 lifecycle 훅 전달.

ZNTC `defineConfig({...})` 가 있으면 `zntc()` 가 자동으로 읽어 옵션을 적용합니다.

## 알려진 한계

- 일부 Vite-only plugin (예: `vite:vue`, `@vitejs/plugin-vue`) 의 SFC 변환은 ZNTC 의 책임 밖입니다. SFC 변환 plugin 은 그대로 사용하시고 ZNTC 는 `<script lang="ts">` 안 TypeScript 만 처리합니다.
- Rollup plugin 의 `this.parse()` ESTree adapter 는 부분 지원 — `info.ast` 같은 ESTree 노드 접근은 [Roadmap](/zntc/roadmap/) 의 Rollup ModuleInfo Phase C 참조.

## 관련 문서

- [Plugin Recipes](/zntc/guides/plugin-recipes/) — Vite plugin 과 함께 쓰는 PostCSS / Tailwind / SVG / GraphQL 등 패턴.
- [Web (standalone)](/zntc/guides/web-starter/) — Vite 없이 ZNTC 만으로 새 프로젝트 시작.
