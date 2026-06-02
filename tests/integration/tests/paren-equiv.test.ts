import { describe, expect, test } from 'bun:test';
import { astEquivalent, normalize } from '../../benchmark/paren-equiv';

// Layer 0 oracle 자가검증(positive control) — 검사기가 실제로 load-bearing 괄호
// 유실을 잡고, 군더더기 괄호 차이는 무시함을 증명한다. 이 self-test 가 없으면
// oracle 이 (망가져서) 늘 true 를 반환해도 회귀 스위트가 silent pass 한다.
// 패턴: src/codegen/codegen_test/helpers.zig 의 assertNoAsyncSelfLoop positive
// control 과 동일 사상.
describe('paren-equiv oracle (positive control)', () => {
  test('load-bearing 괄호 차이 → 비동등(false)', () => {
    expect(astEquivalent('(a + b) * c', 'a + b * c')).toBe(false); // precedence
    expect(astEquivalent('(a?.b).c', 'a?.b.c')).toBe(false); // optional-chain 끊기
    expect(astEquivalent('(function(){})()', 'function(){}()')).toBe(false); // stmt-start(후자 invalid)
    expect(astEquivalent('(-a) ** b', '-a ** b')).toBe(false); // ** 좌단항(후자 invalid)
  });

  test('군더더기 괄호 차이 → 동등(true)', () => {
    expect(astEquivalent('(a) + (b)', 'a + b')).toBe(true);
    expect(astEquivalent('((a + b)) * c', '(a + b) * c')).toBe(true);
    expect(astEquivalent('x = (a + b)', 'x = a + b')).toBe(true);
  });

  test('자기 자신과 동등', () => {
    expect(astEquivalent('(a?.b).c', '(a?.b).c')).toBe(true);
  });

  test('invalid 출력은 비동등으로 처리', () => {
    expect(astEquivalent('a + b', 'a +')).toBe(false); // 후자 SyntaxError
  });

  test('normalize 는 deterministic', () => {
    const s = 'x = a + b * c - d / e';
    expect(normalize(s)).toBe(normalize(s));
  });
});
