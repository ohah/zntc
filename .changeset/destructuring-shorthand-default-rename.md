---
"@zntc/core": patch
---

`--minify` 시 **구조분해 할당의 shorthand + 기본값** 프로퍼티에서 리네임이 누락돼 런타임에 죽던 버그 수정 (#4493).

```
ReferenceError: stackWeight is not defined
```

`({ position: pos, options: { stack, stackWeight = 1 } } = box)` 가 이렇게 방출됐다.

```js
var t,n,r;
({position:t, options:{stack:n, stackWeight:stackWeight=1}} = box);  // ← value 가 원본 이름
```

`stack`(기본값 없는 shorthand)은 `stack:n` 으로 제대로 확장되는데, `stackWeight`(기본값 있는 shorthand)만 value 위치가 **원본 이름 그대로** 남았다. 결과적으로 미선언 전역에 대입되고(strict ESM → `ReferenceError`), 진짜 지역 변수 `r` 은 영영 대입되지 않는다.

원인: `({x = 1} = o)` 는 cover grammar 로 `assignment_target_property_identifier`(left=바인딩, right=기본값)가 된다. 이걸 longhand `key:value=default` 로 펼칠 때 **value 위치를 원본 span 으로 복사**해 mangler 리네임과 namespace 치환을 통째로 건너뛰었다. key(프로퍼티 이름)는 원본을 보존하되 value(바인딩)는 치환을 따라가도록 고쳤다.

선언형(`let {x = 1} = o`)이 아니라 **할당형**(`({x = 1} = o)`)이기만 하면 중첩 여부와 무관하게(최상위 포함) 샜다. `chart.js@4` 의 `buildStacks` 가 정확히 이 패턴을 써서 차트를 렌더할 때 죽었다.

같은 리네임 누락이 두 곳 더 있어 함께 고쳤다.

- **es5 다운레벨**: es5 에서는 codegen 이 아니라 transformer 가 구조분해를 풀어낸다. 이때 합성한 대입 타겟 노드에 symbol_id 를 물려주지 않아, 같은 버그가 다른 emit 경로로 재현됐다.
- **TS namespace**: `namespace N { export let x; ({x = 1} = o); }` 가 `({x:x=1}=o)` 로 방출돼 `N.x` 가 아니라 자유 변수(전역)에 대입됐다 — `--minify` 와 무관하게 값이 조용히 틀리던 표면이다.

**빌드 exit 0 + 산출물 파싱 통과 + 모듈 평가까지 통과**하고 해당 함수를 **호출할 때만** 터지는 계열이라, 번들을 실제로 실행해 값을 확인하는 스모크 게이트를 함께 추가했다. non-strict 포맷에서는 같은 코드가 조용히 전역을 만들고 지역 변수는 `undefined` 로 남는 **무성 오염**이 된다.
