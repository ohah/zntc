---
"@zntc/core": patch
---

minify 시 `if (c) { ({a} = o); g(); }` 를 콤마 시퀀스로 접을 때 **필수 괄호가 사라지던** 버그 수정 (#4472).

`--minify`(= `minify_whitespace` + `minify_syntax`)는 블록 안의 expression statement 들을 `if(c) a,b;` 처럼 콤마 시퀀스로 접는다. 이 경로가 statement-start 를 표시하지 않아, 시퀀스 **첫 원소**가 object destructuring 할당이면 괄호가 빠졌다:

```js
// 입력
if (href) { ({ href, dimensions } = cleanUrl(href)); out.push(href); }

// 잘못된 출력
if(n){href:n,dimensions:r}=t(n),i.push(n);
//    ^ 브라우저는 `{` 를 블록으로, `href:` 를 라벨로 읽는다 → SyntaxError

// 고쳐진 출력
if(n)({href:n,dimensions:r}=t(n)),i.push(n);
```

**빌드는 exit 0 으로 성공하는데 산출물이 런타임에 죽는** silent miscompile 이었다 — `monaco-editor`(marked 의 image 렌더러)를 번들하면 `SyntaxError: Unexpected token ':'` 로 페이지 전체가 실행되지 않았다.

단일 문장 본문(`if (c) ({a} = o);`)은 `emitExpressionStatement` 를 타서 정상이었고, 여러 문장을 접는 경로만 그 마킹을 건너뛰고 있었다. object literal 선두(`({}).toString()`)도 같은 원인으로 깨졌고 함께 고쳐진다. 배열 구조분해(`[a,b] = arr`)는 `[` 가 블록으로 오파싱되지 않으므로 괄호가 붙지 않는다.
