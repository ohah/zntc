---
"@zntc/core": patch
---

`--minify` 의 **dead-store 제거가 살아 있는 대입문을 삭제**하던 무성 오컴파일 수정 (#4503).

```js
let buf = "";
function flush() { out.push(buf); }   // ← buf 를 클로저로 읽는다
function emit(t) {
  buf = t;      // ← dead 가 아니다. 사이의 flush() 가 읽는다.
  flush();
  buf = "";
}
```

`buf = t` 가 통째로 삭제됐다. **빌드 exit 0 · 산출물 파싱 통과 · 런타임 에러 0 · 값만 틀림** — 기존 게이트를 전부 통과하는 계열이다. `highlight.js@11` 코어의 `emitMultiClass` 가 정확히 이 패턴이라, 하이라이팅 결과가 `functionfunction f f(a)` 처럼 깨져 나왔다.

**원인.** DSE 는 두 store 사이에 read 가 있는지를 `Reference` 배열의 위치, 즉 **소스 순서**로 판정한다. 그런데 소스 순서가 실행 순서와 같은 것은 *한 함수의 한 활성화 안에서 straight-line 으로 흐를 때뿐*이다. 이 가정이 깨지는 세 경우를 모두 놓치고 있었다:

1. **클로저 읽기** — 클로저 안의 read 는 소스 위치가 두 store 밖이라 안 보이지만, 실제로는 사이의 호출 시점에 일어난다.
2. **재진입** — read/write 가 같은 함수 안이어도 변수가 함수 **밖** 에 선언됐으면 호출이 겹칠 때 바인딩을 공유한다. 사이의 호출이 재귀하거나 `await` 로 인터리빙되면 *다른 활성화* 가 앞 store 의 값을 읽는다.
3. **abrupt completion** — `x = 1; if (c) break lbl; x = 2;` 처럼 사이에서 흐름이 끊기면 뒤 store 가 실행되지 않아 앞 store 가 살아남는다.

**처방.** 판정이 불확실하면 항상 "유지"(보수적)로 간다.

- read 가 write 와 **다른 실행 단위**(함수/클래스 본문)에 하나라도 있으면 제거 금지.
- 변수의 **선언 실행 단위 ≠ write 실행 단위** 면 제거 금지 (재진입 차단).
- 두 store 사이 statement 가 **바깥 흐름을 끊으면** 제거 금지. 단, 그 사이에 *완전히 포함된* loop/switch 에 묶이는 라벨 없는 `break`/`continue` 와 중첩 함수·메서드의 `return` 은 바깥 흐름과 무관하므로 계속 제거 대상이다.

진짜 dead store(함수 지역변수를 그 함수 안에서 덮어쓰는, DSE 수익의 대부분)는 그대로 제거된다. 대표 라이브러리 11종 실측 size 영향은 **+11 B / 847 KB (+0.0013%)** 이고, 그 +11 B 는 highlight.js 에서 되살아난 대입문 자체다.
