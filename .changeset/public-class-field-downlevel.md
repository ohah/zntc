---
'@zntc/core': patch
---

`--target=es2015` ~ `es2021` 에서 public class field 가 다운레벨되지 않던 문제를 고쳤습니다 (#4629).

public class field(`class C { n = 7 }`)는 **ES2022** 문법인데, 필드 낮추기가 **`class` 비트(ES2015)에 종속**돼 있었습니다. class 전체를 함수로 낮추는 es5 에서만 필드가 생성자로 들어갔고, class 는 네이티브지만 필드는 아닌 **7개 타겟(es2015~es2021)** 에서는 필드가 그대로 남아 타겟 엔진이 **파싱조차 못 했습니다**. 이제 `class_field`(ES2022) 비트로 독립 게이트합니다.

**의미론**: `useDefineForClassFields` 가 기본값(`true`)이면 필드는 대입이 아니라 **own property 정의**입니다. 그래서 `__publicField` 헬퍼로 낮춥니다 — 상위 클래스에 같은 이름의 setter 가 있어도 그 setter 를 타지 않고, 초기값 없는 `u;` 도 `'u' in obj === true` 입니다. `useDefineForClassFields: false` 로 두면 기존 대입 의미론(`this.n = 7`)을 그대로 유지합니다.

⚠️ **동작 변화**: `--target=es5` 의 인스턴스 필드도 이제 정의 의미론을 따릅니다. 예전에는 `this.n = 7` 대입이라 상위 setter 를 타고 초기값 없는 필드가 사라졌습니다 (static 필드는 예전부터 `Object.defineProperty` 를 썼으므로, 이제 둘이 대칭입니다).

static field 와 static block 의 **소스 순서**도 함께 고쳤습니다 — `static a = …; static { … } static b = …` 에서 block 이 필드 뒤로 밀리던 문제입니다.
