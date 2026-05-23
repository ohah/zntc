# RFC — `entryNames` / `cssNames` default `[dir]/[name]` (PR B-4b sub-2, breaking)

| 항목 | 값 |
|---|---|
| 상태 | Accepted, shipped (PR #3699 / #3700 / #3701) |
| 영향 범위 | `entryNames` / `cssNames` default (semver-major) |
| 도입 시점 | sub-2 (`entry_names`/`css_names` default flip), sub-3 (chunkPlaceholderStem discriminator) |
| 동치 비교 | esbuild `outbase` 자동 추론 + `[dir]/[name]` 기본 |

## 요약

zntc 의 `entryNames` / `cssNames` default 를 `[name]` (평면) → `[dir]/[name]` (entry-relative dir prefix) 로 변경. 같은 stem 두 entry 의 path collision 을 disambiguator hash 가 아니라 *자연스러운 dir prefix* 로 해소. esbuild parity.

`chunkNames` (`[name]-[hash]`) / `assetNames` (`[name]-[hash]`) 는 dir 정보 없는 청크 (manualChunks / common / asset) 에 적용되어 **미변경**.

## 동기

옛 default `[name]` 평면은 multi-entry monorepo 에서 두 entry 가 같은 stem (e.g. `pages/a/index.tsx` + `pages/b/index.tsx`) 일 때 `index.js` collision → disambiguator 가 hash suffix 부여로 강제 회피 (`index-<hash>.js`). 사용자가 의도하지 않은 hash 가 stable filename 을 깨뜨리고, CDN 캐시 키도 일관성 잃음.

esbuild 는 `outbase` 자동 추론 + `[dir]/[name]` 으로 자연스러운 dir 보존. zntc 도 같은 정책 채택.

## 변경 내역

### 1. default flip

| 옵션 | 옛 default | 새 default |
|---|---|---|
| `entryNames` | `[name]` | `[dir]/[name]` |
| `cssNames`   | `[name]` | `[dir]/[name]` |
| `chunkNames` | `[name]-[hash]` | 미변경 |
| `assetNames` | `[name]-[hash]` | 미변경 |

### 2. `graph.entry_dir` common-parent 계산

옛 코드는 `dirname(entry_points[0])` 만 보고 → multi-entry 의 sibling 들이 entry_dir 외부 → `[dir]` 토큰이 `""` 로 치환되어 평면 출력. 새 코드는 esbuild `outbase` 와 동치인 longest common parent (`computeEntryDir`) 계산.

엣지케이스:
- single entry: dirname 그대로
- sibling entries: 둘의 dirname 의 common parent (segment 경계 cut)
- 한쪽이 다른 쪽의 dir prefix: 그쪽 반환 (`/x/y` vs `/x/y/z` → `/x/y`)
- root sep 보존: `/a` vs `/b` → `/`
- 상대 + 절대 mix 또는 분리된 path: `""` 폴백 (평면 emit)

### 3. `cssNames` NAPI 매핑 누락 fix (pre-existing)

PR B-2 에서 Zig `BundleOptions.css_names` field 만 추가하고 NAPI 바인딩 (`packages/core/src/napi/options.zig`) 의 `cssNames` 매핑이 빠진 채 main 머지된 상태였다. 사용자 명시값이 *완전히 무시* 되고 Zig default 만 적용. sub-2 의 default 변경 효과 검증 과정에서 발견 → 동반 fix:
- `packages/core/src/napi/options.zig` — `ownStr` 매핑 + struct field assign
- `packages/core/index.ts` — `BuildOptions.cssNames` TS 타입
- `packages/core/src/typo-suggest.ts` — `KNOWN_CONFIG_KEYS`
- `packages/core/bin/cli-flags.mjs` — `--css-names` CLI flag
- `packages/core/bin/zntc.mjs` — opts default / SCALAR merge / runBundle 인자
- `src/config_options_dto_test.zig` — `bundler_only_fields` drift guard

### 4. `chunkPlaceholderStem` discriminator (sub-3)

옛 코드 `is_entry = chunk.name != null` 는 manualChunks 청크도 name 이 set 돼 entry_names 가 잘못 적용 → name_dir="" 라 stem="vendor" 가 dep_stem 으로 들어가 cross-chunk import 계산 시 `./.js` 깨짐. 정확한 discriminator 는 `chunk.kind == .entry_point`. manualChunks / common 청크는 chunk_names 적용 + dir 강제 "".

### 5. F7 critical — `applyCssNamingPattern` 의 `[dir]` 토큰 미지원

non-splitting / preserve-modules CSS 경로 (`emitCssBundle`) 가 새 default `[dir]/[name]` 를 literal 로 받아들여 파일명에 `[dir]/` 가 baked 되던 critical 버그 (Windows 불법 파일명). `applyCssChunkNameWithDir` 와 동일한 [dir]/빈-dir-skip 규칙으로 구현.

## 마이그레이션 가이드

### 옛 평면 동작이 필요한 경우

명시적 opt-out:

```js
// zntc.config.ts
export default {
  entryNames: '[name]',
  cssNames: '[name]',
};
```

또는 CLI:

```sh
zntc --entry-names='[name]' --css-names='[name]' src/index.ts
```

### 새 default 가 효과 없는 경우 — 디버깅

`[dir]/[name]` 적용 후에도 path 가 평면이면 다음을 확인:

1. **entry_dir 가 계산됐는지** — 모든 entry 가 같은 root prefix 를 공유해야. 절대/상대 path mix 면 `""` 폴백.
2. **chunk.kind** — manualChunks 청크는 의도적으로 chunk_names (`[name]-[hash]`) 사용. entry chunk 만 entry_names.
3. **app-builder** — `src/app/build.zig` 는 HTML link rewrite 호환 위해 명시적 opt-out (`.entry_names = "[name]"`, `.css_names = "[name]"`).

### MF (Module Federation) 사용자

`remoteEntry` path 는 `formatRemoteEntryPath` (PR B-4b sub-1b) 가 정규화하므로 새 default 영향 없음. expose chunk path 는 source dir 의 자연스러운 prefix 가 붙음 — manifest 의 `assets.js.async` 항목은 `outputs[*].path` 를 그대로 사용해 자동 일치.

### app-builder 사용자

zntc 의 app-builder (`zntc app build` 또는 SPA HTML 자동 link rewrite) 는 의도적으로 `entry_names = "[name]"` / `css_names = "[name]"` 옵트아웃 유지 — HTML `<script src="...">` / `<link href="...">` rewrite 가 평면 path 가정. 사용자가 app-builder 모드에서 dir prefix 가 필요하면 별도 issue.

## 검증

- zig build test 전체 pass
- packages/core 1021/1021 pass
- 통합 manualChunks smoke isolated 32/32, NAPI bridge isolated 44/44 pass
- RN example app fixture 재생성 (sub-3 PR #3701)

## 후속 (미해결)

| 항목 | 추적 |
|---|---|
| `buildIncremental` 의 entry_dir 갱신 watch test (entry 추가/삭제 시 stale) | Issue #65 |
| 사용자가 `entryNames` / `cssNames` 를 *다른 dir* 로 강제 시 dynamic 청크 `<link>` href 어긋남 | docs/BUNDLER.md "알려진 한계" |
| `outbase` 옵션 명시적 override (현재 silent 무시) | sub-4 별도 PR 후보 |

## 참조

- esbuild `outbase`: https://esbuild.github.io/api/#outbase
- esbuild `entry-names`: https://esbuild.github.io/api/#entry-names
- PR #3699 (sub-2): default flip + 2 root cause
- PR #3700 (sub-3a): chunkPlaceholderStem discriminator
- PR #3701 (sub-3b): RN fixture 재생성
