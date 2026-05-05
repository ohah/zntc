import { describe, expect, test } from 'bun:test';

import { escapeRegex } from './escape-regex.ts';

describe('escapeRegex', () => {
  test('special char 모두 escape', () => {
    expect(escapeRegex('.')).toBe('\\.');
    expect(escapeRegex('*')).toBe('\\*');
    expect(escapeRegex('+')).toBe('\\+');
    expect(escapeRegex('?')).toBe('\\?');
    expect(escapeRegex('^')).toBe('\\^');
    expect(escapeRegex('$')).toBe('\\$');
    expect(escapeRegex('{')).toBe('\\{');
    expect(escapeRegex('}')).toBe('\\}');
    expect(escapeRegex('(')).toBe('\\(');
    expect(escapeRegex(')')).toBe('\\)');
    expect(escapeRegex('|')).toBe('\\|');
    expect(escapeRegex('[')).toBe('\\[');
    expect(escapeRegex(']')).toBe('\\]');
    expect(escapeRegex('\\')).toBe('\\\\');
  });

  test('plain string 은 변경 없음', () => {
    expect(escapeRegex('hello')).toBe('hello');
    expect(escapeRegex('ABC123_xyz')).toBe('ABC123_xyz');
    expect(escapeRegex('')).toBe('');
  });

  test('string 안의 special + plain 혼합', () => {
    expect(escapeRegex('a.b.c')).toBe('a\\.b\\.c');
    expect(escapeRegex('foo.png')).toBe('foo\\.png');
    expect(escapeRegex('(group)+')).toBe('\\(group\\)\\+');
  });

  test('Metro asset path 패턴 (.png/.jpg 등)', () => {
    const exts = ['.png', '.jpg', '.gif', '.svg'];
    for (const ext of exts) {
      const escaped = escapeRegex(ext);
      const re = new RegExp(`${escaped}$`);
      expect(re.test(`/abs/path/file${ext}`)).toBe(true);
      expect(re.test(`/abs/path/file${ext}.bak`)).toBe(false);
    }
  });

  test('`new RegExp(escapeRegex(s))` round-trip — literal 매칭', () => {
    const literals = [
      'a.b.c',
      '$variable',
      '(group)',
      '[set]',
      '{block}',
      'back\\slash',
      'wild*card',
    ];
    for (const literal of literals) {
      const re = new RegExp(escapeRegex(literal));
      expect(re.test(literal)).toBe(true);
      // 다른 매칭 안 됨 (literal 그대로 만 매칭).
      expect(re.test(literal.replaceAll(literal[0], 'X'))).toBe(false);
    }
  });

  test('같은 input 에 같은 output (deterministic)', () => {
    expect(escapeRegex('foo.bar')).toBe(escapeRegex('foo.bar'));
  });

  test('multi-byte / Unicode 그대로 보존', () => {
    expect(escapeRegex('한글')).toBe('한글');
    expect(escapeRegex('emoji.🎉')).toBe('emoji\\.🎉');
  });
});
