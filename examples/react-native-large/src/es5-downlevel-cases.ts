/**
 * ES5 다운레벨 스트레스 테스트 케이스.
 *
 * TEMP: 좁히기 — async FUNCTION (method shorthand 아님) + computed object.
 * 가설: 트리거는 method shorthand 한정인지, async/generator 다운레벨 자체인지.
 */

export async function asyncFunction() {
  return 2;
}

export function computedObject() {
  const o = { ['staticKey']: 42 };
  return o;
}

export const es5DownlevelCases = {
  asyncFunction,
  computedObject,
};
