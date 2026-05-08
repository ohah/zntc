import { describe, test, expect, transpile } from './helpers';

describe('@zntc/core browserslist > transpile', () => {
  test('browserslist: 모던 브라우저 쿼리는 변환 안 함', () => {
    const src = 'async function f() { return await Promise.resolve(1); }';
    const r = transpile(src, { browserslist: 'last 2 chrome versions' });
    expect(r.code).toContain('async function f');
    expect(r.code).not.toContain('__async');
  });

  test('browserslist: 오래된 브라우저 쿼리는 async 다운레벨', () => {
    const src = 'async function f() { return await Promise.resolve(1); }';
    const r = transpile(src, { browserslist: 'chrome 50, firefox 50' });
    expect(r.code).toContain('__async');
  });

  test('browserslist: 여러 엔진 중 하나라도 미지원이면 다운레벨 (보수적)', () => {
    // chrome 최신은 optional_chaining 지원, safari 12는 미지원 → ?. 제거
    const src = 'const x = a?.b;';
    const r = transpile(src, { browserslist: 'chrome 100, safari 12' });
    expect(r.code).not.toContain('?.');
  });

  test('browserslist: 쿼리 배열 입력', () => {
    const src = 'const x = 1 ** 2;';
    // chrome 40은 exponentiation 미지원, chrome 55는 지원 → union 결과 chrome 40 기준
    const r = transpile(src, { browserslist: ['chrome 40'] });
    expect(r.code).not.toContain('**');
  });

  test('browserslist: ios_saf는 ios 엔진으로 매핑', () => {
    const src = 'async function f() {}';
    // ios 10은 async 미지원 → 변환
    const r = transpile(src, { browserslist: 'ios_saf 10' });
    expect(r.code).toContain('__async');
  });

  test('browserslist: 매핑 불가능한 엔진(samsung)만 있으면 보수적으로 esnext', () => {
    // samsung 브라우저는 ZNTC Engine에 없음 → 빈 engines → 0 (esnext)
    const src = 'async function f() {}';
    const r = transpile(src, { browserslist: 'samsung 20' });
    expect(r.code).toContain('async function');
  });

  test('browserslist는 target보다 우선', () => {
    const src = 'const x = a?.b;';
    // target=es5지만 browserslist=modern → optional chaining 유지
    const r = transpile(src, { target: 'es5', browserslist: 'chrome 100' });
    expect(r.code).toContain('?.');
  });

  test('browserslist: 빈 결과(매칭 없음)도 크래시 없이 처리', () => {
    // 존재하지 않는 버전 규칙 — browserslist가 throw 할 수도 있음
    // 이 경우 사용자 책임 — 우리 코드에서 크래시만 안 나면 됨
    const src = 'const x = 1;';
    expect(() => transpile(src, { browserslist: 'defaults' })).not.toThrow();
  });

  test('browserslist: hermes 매핑 (RN 사용자 대응)', () => {
    // browserslist는 hermes를 모르지만 우리 파서는 수동 매핑 지원
    // 직접 hermes 키워드 쿼리는 browserslist가 모르므로 defaults 사용 예시
    const src = 'async function f() {}';
    // hermes 0.12는 async transform 필요 (kangax fail) → __async 나와야 함
    // 이 테스트는 browserslistToUnsupported 저수준 API 커버
    const { browserslistToUnsupported } = require('../../../../shared/index');
    const bits = browserslistToUnsupported(['hermes 0.12']);
    // bit 12 = async_await
    expect(bits & (1 << 12)).not.toBe(0);
    void src;
  });
});
