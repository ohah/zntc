/**
 * Semantic-equivalence oracle — codegen precedence 전환(#4042)용.
 *
 * 전환은 byte-identical 을 의도적으로 깬다(군더더기 괄호 제거). 따라서 회귀
 * 기준을 "두 출력이 괄호 차이를 빼면 같은 프로그램인가"(semantic equivalence)
 * 로 둔다.
 *
 * esbuild 를 정규화기(normalizer)로 쓴다: `minify:false` 로 재파싱·재출력하면
 * esbuild 자신의 최소-괄호 정책으로 redundant 괄호가 제거되고 형식이 통일되므로,
 * 두 소스의 정규화 결과가 같으면 (불필요 괄호 차이만 있는) 같은 파스 트리다.
 * load-bearing 괄호가 빠지면 파스가 달라져 정규화 결과도 달라진다. esbuild 가
 * 정규화기로 적합한 이유는 이 전환의 목표 자체가 "esbuild/oxc 식 최소 괄호"이기
 * 때문이다 — oracle 과 목표가 일치한다.
 *
 * 한쪽이 파싱 불가(invalid)면 비동등으로 본다 — load-bearing 괄호 유실로
 * SyntaxError 가 된 출력을 잡아낸다.
 */

import { transformSync } from 'esbuild';

/** esbuild 로 재파싱·재출력해 괄호/형식을 정규화한다. 입력은 트랜스파일된 JS 가정. */
export function normalize(src: string): string {
  return transformSync(src, { minify: false, loader: 'js' }).code;
}

/**
 * 두 JS 소스가 (불필요 괄호 차이를 제외하고) 의미상 동일한가.
 * 한쪽이라도 invalid 면 false (load-bearing 괄호 유실 → invalid 출력을 포착).
 */
export function astEquivalent(a: string, b: string): boolean {
  let na: string;
  let nb: string;
  try {
    na = normalize(a);
  } catch {
    return false;
  }
  try {
    nb = normalize(b);
  } catch {
    return false;
  }
  return na === nb;
}
