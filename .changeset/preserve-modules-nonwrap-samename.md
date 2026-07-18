---
"@zntc/core": patch
---

`--preserve-modules`(ESM/CJS)에서 **비-ESM-wrap** 동명 export 를 한 소비자가 여러 파일에서 import 하면 붕괴하던 것 수정 (#4572).

```js
// m1.js/m2.js/m3.js: 각각 export function tag(){ return "T1/T2/T3"; }
// a.cjs: module.exports = require("./m1.js"); require("./m2.js");   // m1·m2 만 ESM-wrap
// entry: import { tag as t1 } from "./m1.js"; import { tag as t2 } from "./m2.js";
//        import { tag as t3 } from "./m3.js"; import "./a.cjs";
//        console.log(t1() + t2() + t3());
// node canonical: "T1T2T3"
// 버그: "T1T2T1"  ← t3 이 m1 의 tag 로 붕괴
```

## 근본 원인

소비자 import 블록(emitter, `chunks.zig`)은 같은 export 명이 여러 dep 에서 오면 `import { tag as tag$3 }` 로 **소비자-로컬** deconflict 하는데(provider public 명 `export { tag }` 은 유지 — external API 계약), 소비자 **body 참조**(linker `effective_target`)는 `crossChunkBindingName` = `tag`(m1 과 충돌) 로 붕괴한다. 전역명이 ESM-wrap owner 로 한정(#4559)돼 non-wrap 은 전역명이 없고, import 블록의 `$N` deconflict 는 body 와 공유되지 않았다(코드 주석도 이 divergence 를 인정).

## 수정 (rollup 식 — provider public 명 보존)

전역명을 non-wrap 에 확장하면 provider public export 가 리네임돼 external consumer 가 깨진다(preserve-modules 계약 위반). 대신 **소비자-로컬 deconflict 를 body 와 공유**한다:

- import 블록이 body codegen(`buildMetadataForAst`)보다 **먼저** 방출되므로, `$N` deconflict 로 정한 소비자-로컬명(`tag$3`)을 `consumer_import_local`(per-chunk transient, `canonical module → export명 → 로컬명`)에 적어 둔다(linker.zig).
- `effective_target` 가 전역명이 없는 cross-chunk 참조에서 이 맵을 읽어 body 를 같은 이름(`tag$3`)으로 맞춘다. import 문·body 가 일치하고 provider 는 `export { tag }` 그대로다.

`/code-review max` 반영:
- **explicit preserve-modules 게이트**: `consumer_import_local` 의 write(chunks.zig)·read(effective_target)를 `preserve_modules` 로 명시 게이트(암묵적 `!has_global` 대신). splitting 은 전역명이 있어 이 경로를 안 타므로 무영향이 코드에 드러난다.
- **borrowed `loc` UAF 회피 명시**: map 은 non-wrap(.none) canonical 에서만 채워지므로, per-chunk 수명 borrowed `loc` 이 esm-wrap 전용 `export_getter_overrides` 경로로 안 흘러감을 주석에 못박음(renames 경로는 이미 dupe).

## 검증

- 회귀 스위트 `preserve-modules-nonwrap-samename.test.ts` 24종(esm/cjs × plain/minify): 혼합(wrap+non-wrap), 순수 non-wrap, 동명 const, re-export 배럴, 다단계 re-export 체인, 2-consumer — 전부 통과(수정 전 전부 붕괴).
- provider public 명(`export { tag }`)·entry 자체 export 자연명 유지 확인.
- zig 전체 test, 통합 스위트 무회귀. splitting·단일 번들 무영향(write/read 모두 preserve_modules 게이트).

## 잔여 (별개 근본 — #4576)

- **동명 `export default` / `export { foo as tag }`**(export 명 ≠ 소비자 로컬명): import 블록의 `key != binding` 분기가 `$N` deconflict·map 기록을 안 해 로컬명 중복(default esm=SyntaxError·minify=silent ND1ND1·cjs 별도). binding-keyed deconflict + cjs/minify emit 경로별 처리 필요. #4572 인프라(`consumer_import_local`)를 확장하는 후속.
