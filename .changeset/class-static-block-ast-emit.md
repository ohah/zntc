---
"@zntc/core": patch
---

class static block 을 소스 원문 복사가 아니라 AST 로 출력한다 (#4468).

`emitStaticBlock` 이 non-minify 경로에서 `writeNodeSpan` 으로 **소스 바이트를 그대로 복사**하고 있었다. 그래서 static block 안에서만 AST 에 가해진 변형이 통째로 유실됐다 — 조용한 오컴파일.

### 유실되던 것들

- **deconflict rename**: `class Node` 가 `Node$1` 로 rename 돼도 블록 안의 자기참조 `new Node(...)` 는 옛 이름으로 남았다. 번들에 `Node` 선언이 없으니 그 참조는 **전역 바인딩을 탈취**한다 — 브라우저에서 `new Node()` 는 DOM `Node` 를 잡아 `TypeError: Illegal constructor` 로 죽는다. `monaco-editor` 의 `vs/base/common/linkedList.js` 가 정확히 이 패턴이라, `zntc build` 로 번들한 monaco 는 **에디터가 아예 뜨지 않았다**.
- **TypeScript strip**: `static { getX = (obj: C) => obj.#x; }` 의 타입 주석 `: C` 가 그대로 남아 **문법적으로 깨진 JS** 가 나왔다.
- **`--define` 치환**: `static { this.mode = __MODE__; }` 의 `__MODE__` 가 그대로 남아 런타임 `ReferenceError`.
- 주석이 클래스 밖으로 중복 출력되고, 들여쓰기가 원본 소스 것과 codegen 것으로 뒤섞였다.

minify 경로는 이미 AST 로 출력하고 있었고 그쪽은 정상이었다 — 즉 AST 출력은 이미 검증된 경로였고, 원문 복사 지름길만 그걸 건너뛰고 있었다. 그 지름길을 제거했다.

### 출력 변화

static block 이 다른 블록과 동일하게 포맷된다. `minify_syntax` 가 꺼진 상태에서는 statement 종결 `;` 가 붙는다 (다른 모든 블록과 같은 규칙).

```js
// 이전 (소스 원문 복사 — 들여쓰기가 뒤섞임)
class C {
	static {
        const a = 1;

    }

}

// 이후 (AST 출력)
class C {
	static {
		const a = 1;
	}
}
```
