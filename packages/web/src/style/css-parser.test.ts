import { describe, expect, test } from 'bun:test';
import {
  isCssIdent,
  isCssIdentStart,
  skipCssString,
  skipCssUrl,
  startsWithCssIdent,
} from './css-parser.ts';

describe('skipCssString', () => {
  test('정상 종료 quote 까지 skip', () => {
    const css = `"hello"end`;
    // 0=" 1=h ... 6=" → return 7
    expect(skipCssString(css, 0, '"')).toBe(7);
  });

  test('escape sequence 는 1 단위로 skip', () => {
    const css = `"a\\"b"end`; // a\"b
    expect(skipCssString(css, 0, '"')).toBe(6);
  });

  test('닫히지 않은 string 은 css 끝까지', () => {
    expect(skipCssString(`"oops`, 0, '"')).toBe(5);
  });

  test('끝에 backslash 만 있어도 안전', () => {
    expect(skipCssString(`"a\\`, 0, '"')).toBe(3);
  });

  test('작은따옴표 quote', () => {
    expect(skipCssString(`'x'after`, 0, "'")).toBe(3);
  });

  test('내부 다른 quote 는 skip 대상 아님', () => {
    expect(skipCssString(`"can't"x`, 0, '"')).toBe(7);
  });
});

describe('skipCssUrl', () => {
  test('plain url() 의 ) 다음 위치', () => {
    const css = `url(./a.png) end`;
    // start=4 (url( 다음). a.png) → ) at index 11, return 12
    expect(skipCssUrl(css, 4)).toBe(12);
  });

  test('인용된 url 도 정상 처리', () => {
    const css = `url("./a)b.png") end`;
    expect(skipCssUrl(css, 4)).toBe(16);
  });

  test('작은따옴표 인용된 url', () => {
    const css = `url('./a)b.png') end`;
    expect(skipCssUrl(css, 4)).toBe(16);
  });

  test('닫히지 않은 url 은 css 끝까지', () => {
    expect(skipCssUrl(`url(broken`, 4)).toBe(10);
  });

  test('escaped quote 는 string 시작 아님', () => {
    const css = `url(a\\"b)c`;
    expect(skipCssUrl(css, 4)).toBe(9);
  });
});

describe('startsWithCssIdent', () => {
  test('정확 일치', () => {
    expect(startsWithCssIdent('@import xxx', 0, '@import')).toBe(true);
  });

  test('case-insensitive', () => {
    expect(startsWithCssIdent('@IMPORT', 0, '@import')).toBe(true);
    expect(startsWithCssIdent('@Import', 0, '@import')).toBe(true);
  });

  test('offset 적용', () => {
    expect(startsWithCssIdent('xxx@import', 3, '@import')).toBe(true);
  });

  test('불일치', () => {
    expect(startsWithCssIdent('@imp', 0, '@import')).toBe(false);
    expect(startsWithCssIdent('@export', 0, '@import')).toBe(false);
  });
});

describe('isCssIdentStart', () => {
  test('underscore', () => {
    expect(isCssIdentStart('_')).toBe(true);
  });

  test('대문자 A-Z', () => {
    expect(isCssIdentStart('A')).toBe(true);
    expect(isCssIdentStart('Z')).toBe(true);
    expect(isCssIdentStart('M')).toBe(true);
  });

  test('소문자 a-z', () => {
    expect(isCssIdentStart('a')).toBe(true);
    expect(isCssIdentStart('z')).toBe(true);
  });

  test('숫자 거부', () => {
    expect(isCssIdentStart('0')).toBe(false);
    expect(isCssIdentStart('9')).toBe(false);
  });

  test('hyphen 거부 (start 아님)', () => {
    expect(isCssIdentStart('-')).toBe(false);
  });

  test('공백 / 특수문자', () => {
    expect(isCssIdentStart(' ')).toBe(false);
    expect(isCssIdentStart('@')).toBe(false);
    expect(isCssIdentStart('.')).toBe(false);
  });
});

describe('isCssIdent', () => {
  test('ident-start 전부 통과', () => {
    expect(isCssIdent('_')).toBe(true);
    expect(isCssIdent('A')).toBe(true);
    expect(isCssIdent('z')).toBe(true);
  });

  test('hyphen 통과 (start 아닌 위치)', () => {
    expect(isCssIdent('-')).toBe(true);
  });

  test('숫자 통과', () => {
    expect(isCssIdent('0')).toBe(true);
    expect(isCssIdent('5')).toBe(true);
    expect(isCssIdent('9')).toBe(true);
  });

  test('공백 / 특수문자 거부', () => {
    expect(isCssIdent(' ')).toBe(false);
    expect(isCssIdent('@')).toBe(false);
    expect(isCssIdent('.')).toBe(false);
  });
});
