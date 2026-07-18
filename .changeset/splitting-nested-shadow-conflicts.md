---
"@zntc/core": patch
---

`--splitting` 에서 함수-로컬 `const x` 가 import 가 해석되는 module-level `const x` 를 shadow 할 때, 초기화식이 로컬 자신을 참조하는 **self-TDZ**(`const channels = channels.set(...)`)가 되던 것 수정 (#4563).

```js
// reusable.js:  const channels = new Channels(...); export default channels;   // 싱글톤
// rgba.js:
import _channels from "./reusable.js";
const rgba = (r) => {
  const channels = _channels.set({ r });   // 로컬 channels 가 싱글톤 channels 를 shadow
  return channels;
};
// 버그(splitting): const channels = channels.set(...) → ReferenceError: Cannot access 'channels' before initialization
```

실제 mermaid 를 `--format=esm`(minify 없이)로 빌드하면 khroma(rgba 등)가 이 위상으로 인라인돼 `channels` self-TDZ 로 `mermaid.render()` 가 크래시했다. (#4560/#4564 로 **minify** 경로는 이미 렌더됐고, 이건 **non-minify** 경로 블로커.)

## 근본 원인

zntc 가 import 참조 `_channels` 를 싱글톤 canonical `channels` 로 해석하면 함수-로컬 `channels` 와 충돌한다. **비-splitting**(글로벌 `computeRenames`)은 `resolveNestedShadowConflicts` 로 이 충돌을 감지해 싱글톤 canonical 을 `channels$1` 로 리네임하는데, **splitting** 의 per-chunk 리네이머(`computeRenamesForModules`)엔 그 패스가 빠져 있었다 → splitting 에서만 로컬이 싱글톤을 가려 self-TDZ.

## 수정

`computeRenamesForModules`(per-chunk)에 `resolveNestedShadowConflicts` 를 추가한다(글로벌 경로와 동일 위치). `only: ?[]const ModuleIndex` 파라미터로 청크 모듈 한정, **target(정의)이 consumer 와 같은 청크일 때만** 리네임.

`/code-review max` 반영:
- **preserve-modules(module_to_chunk==null) 제외**: null 이면 `chunkOfModule` 이 전부 `.none` → same-chunk 가드가 `.none != .none`=false 로 fail-open 해 cross-module target 을 over-rename(별도 출력 파일이 원명 export → ReferenceError). preserve-modules 는 import 를 hoisting 안 해 이 shadow 자체가 없으므로 `if (module_to_chunk != null)` 로 skip. same-chunk 가드도 `.none` 이면 skip(isCrossChunkConsumer 와 동형).
- **nested-binding 캐시를 `calculateRenames` 전 + `defer clearNestedBindingCache()`**: 3 소비처(calculateRenames/resolveNestedShadowConflicts/resolveWrapperConsumerShadows) 공용 O(1), 에러 경로 해제.

## 범위 / 후속

**same-chunk splitting** 한정(mermaid khroma 는 same-chunk 인라인이라 커버). 같은 클래스의 잔여 토폴로지 — (A) cross-chunk splitting(싱글톤이 다른 청크), (B) preserve-modules(import 로컬명 shadow), (C) dev-split override revert — 는 근본이 **cross-chunk/파일경계 네이밍이 소비자 nested binding 미회피**로 별개 처방 필요. 셋 다 #4563 이전부터 있던 pre-existing gap(이 PR 이 회귀시키지 않음) → **#4566** 로 추적.

## 검증

- 실제 mermaid `--format=esm`(non-minify): flowchart/sequence/gantt/class/state/pie/er/journey/git **9종 전부 headless 브라우저 렌더 성공**. 산출물 self-referencing const 0. (minify 경로도 여전히 9종 렌더 — #4560/#4564.)
- 회귀 가드: `split-runtime-smoke.test.ts` `#4563` — reusable 싱글톤 + import alias + 함수-로컬 동명 구조를 splitting 으로 node 실행(`rgba:10`), self-referencing const 부재 확인. 수정 전 self-TDZ `ReferenceError` 재현.
- zig 전체 test + 통합 스위트(4268) 무회귀 — per-chunk 리네이머는 모든 splitting 빌드가 타는 코어 경로라 전량 검증.
