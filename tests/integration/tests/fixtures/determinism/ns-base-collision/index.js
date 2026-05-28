// #3966 회귀: 서로 다른 디렉터리의 동일 basename(`core`/`patch`) 모듈을
// namespace 로 import 하고 *값으로* 사용한다. 값 사용이 shared-ns inline
// 객체 materialize 를 강제(force_inline) → `core_ns`/`core_ns_2`/... 변수명이
// 발급된다. 병렬 emit 에서 이 이름의 base/suffix 배정이 비결정이었음(#3966).
import * as coreA from './a/core.js';
import * as coreB from './b/core.js';
import * as coreC from './c/core.js';
import * as patchA from './a/patch.js';
import * as patchB from './b/patch.js';

// namespace 객체를 값으로 노출 → inline materialize 강제.
const registry = [coreA, coreB, coreC, patchA, patchB];

export function run(x) {
  let acc = coreA.make(x);
  acc = patchA.apply(acc);
  acc = patchB.apply(coreB.make(x));
  return { acc, c: coreC.make(x), n: registry.length };
}
