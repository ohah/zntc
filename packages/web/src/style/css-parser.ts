// CSS low-level scanner — postcss/sass/css-modules pipeline 의 공통 helper.
// platform-agnostic 이지만 web 의 dev pipeline 안에서만 사용되므로 web 의 style/
// 디렉토리에 자리잡음. zntc.mjs 의 동등 함수 (L1177-1213) 는 PR #5e (css-modules
// 추출) 시점에 본 모듈 import 로 redirect 후 zntc.mjs 잔존본 제거.

/**
 * `start` 가 가리키는 css string literal 끝 다음 위치 반환. `\` escape 와
 * 종료 quote 를 인식. 닫히지 않은 문자열은 css 끝까지 skip.
 */
export function skipCssString(css: string, start: number, quote: string): number {
  let i = start + 1;
  while (i < css.length) {
    if (css[i] === '\\' && i + 1 < css.length) {
      i += 2;
      continue;
    }
    if (css[i] === quote) return i + 1;
    i += 1;
  }
  return css.length;
}

/**
 * `url(...)` 안의 끝 `)` 다음 위치 반환. 인용된 url 도 string skip 으로 안전 처리.
 */
export function skipCssUrl(css: string, start: number): number {
  let i = start;
  while (i < css.length) {
    if ((css[i] === '"' || css[i] === "'") && css[i - 1] !== '\\') {
      i = skipCssString(css, i, css[i]!);
      continue;
    }
    if (css[i] === ')') return i + 1;
    i += 1;
  }
  return css.length;
}

/** `css` 의 `offset` 부터 `value` 와 case-insensitive 일치하는지 확인. */
export function startsWithCssIdent(css: string, offset: number, value: string): boolean {
  return css.slice(offset, offset + value.length).toLowerCase() === value;
}

/** CSS identifier 시작 가능 문자 (`_`, `A-Z`, `a-z`). */
export function isCssIdentStart(ch: string): boolean {
  return ch === '_' || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z');
}

/** CSS identifier 내부 가능 문자 (시작 문자 + `-` + `0-9`). */
export function isCssIdent(ch: string): boolean {
  return isCssIdentStart(ch) || ch === '-' || (ch >= '0' && ch <= '9');
}
