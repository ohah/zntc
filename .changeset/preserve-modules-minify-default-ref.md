---
"@zntc/core": patch
---

`--preserve-modules --minify`(또는 `--minify-identifiers`)에서 소비자의 **default import** body 참조가 발산해 `foo is not defined`/`TypeError` 로 실패하던 것 수정 (#4579).

```js
// m1.js: export default function foo(){ return "D1"; }
// entry: import a from "./m1.js"; console.log(a());
// (minify) → const t = require("./m1.js"); console.log(foo());  // ← import=t, body=foo 발산
```

## 근본 (per-chunk rename_table 타이밍)

import 문 로컬명과 body 참조 둘 다 `resolveToLocalName(provider,"default")` → `rename_table` 을 읽는다. 그런데 `computeRenamesForModules` 는 **청크마다** 맨 처음 `clearCanonicalNames()` 로 `rename_table` 을 비우고 현재 청크만 다시 mangle 한다.

- **import 블록**은 그 clear **전**에 방출돼 provider(m1) 청크의 mangle `foo→t` 를 본다 → `t`.
- **body 참조**(effective_target)는 소비자 청크 emit 중(clear **후**)에 계산돼 m1 의 mangle 이 wipe된 stale `rename_table` 을 읽는다 → 원본 `foo`.

default 는 안정된 public export 명이 없어(`module.exports = X`) provider 의 **로컬명**을 써야 하므로 특히 발산한다(named import 는 public 명 `exports.foo` 라 무영향). splitting 은 cross-chunk 전역명이 있어 무영향.

## 수정

import 블록은 rename_table 이 유효한 시점에 이미 올바른 provider-mangled 로컬(`t`)을 구한다. 이를 `deconflictedConsumerLocal` 에서 **항상** `consumer_import_local`(#4576) 에 기록하도록 바꿔(기존엔 deconflict `local != binding` 일 때만), body 의 effective_target 이 그 값을 읽어 정합시킨다. import 문이 body 참조의 유일 권위.

이 fix 로 #4576(동명 default)·#4580(default interop) 의 `--minify` 도 함께 풀린다(그 PR 들이 남긴 minify 한계 해소).

## 검증

- 회귀 스위트 `preserve-modules-minify-default-ref.test.ts` 8종: 단일 default·동명 default 2개·default+named·default class × esm/cjs, 전부 `--minify` 로 정확한 출력.
- preserve-modules·cross-chunk·splitting·wrapper 통합 310 + zig 전체 무회귀.
