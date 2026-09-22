/**
 * `UnsupportedFeatures` 비트마스크의 **Zig ↔ JS 미러 대조**.
 *
 * 왜 필요한가: NAPI transpile 경로에서 `target: 'es2017'` 같은 ES 타겟은 JS 가
 * `packages/shared/index.ts` 의 `ES_TARGET_BITS` 로 **직접 환산해** `unsupported`
 * 로 실어 보내고, Zig 는 그 값을 target 문자열보다 **우선** 적용한다. 즉 이 표는
 * 주석이 아니라 실제로 다운레벨을 결정하는 정본이다 — Zig 에 feature 를 추가하고
 * 이 표를 안 고치면, 그 feature 는 NAPI 로 빌드할 때만 조용히 다운레벨되지 않는다
 * (CLI 는 Zig 계산을 쓰므로 정상 — 그래서 CLI 로만 확인하면 못 잡는다).
 */

import { describe, test, expect } from '../helpers';
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ES_TARGET_BITS } from '../../../../shared/index';
import { FEATURES, computeUnsupportedFromEngines } from '../../../../shared/compat-engines';

interface UnsupportedNative {
  targetToUnsupported(spec: string): number;
}

function loadNative(): UnsupportedNative {
  const here = dirname(fileURLToPath(import.meta.url));
  const req = createRequire(import.meta.url);
  // index.ts 의 findAddon() 과 같은 우선순위. CI 는 `zig build napi` 직후
  // `cp zig-out/lib/zntc.node packages/core/zntc.node` 를 하므로 둘 다 후보다.
  const candidates = [
    '../../../../../zig-out/lib/zntc.node', // repo root (monorepo dev)
    '../../../zntc.node', // packages/core/zntc.node (CI 가 복사해 두는 자리)
  ];
  for (const rel of candidates) {
    const p = join(here, rel);
    if (existsSync(p)) return req(p) as UnsupportedNative;
  }
  throw new Error(
    `zntc.node 를 찾지 못했다 — \`zig build napi\` 를 먼저 실행할 것 (찾아본 곳: ${candidates
      .map((r) => join(here, r))
      .join(', ')})`,
  );
}

/** 2^31 이상을 다루므로 `>>>`/`&` 를 쓸 수 없다(int32 로 잘린다). */
function popcount(n: number): number {
  let c = 0;
  for (let b = BigInt(n); b > 0n; b >>= 1n) if (b & 1n) c++;
  return c;
}

describe('UnsupportedFeatures 비트마스크: Zig ↔ JS 미러', () => {
  const native = loadNative();
  const esTargets = Object.keys(ES_TARGET_BITS);

  test.each(esTargets)('ES_TARGET_BITS[%s] 가 네이티브 계산과 일치', (target) => {
    expect(native.targetToUnsupported(target)).toBe(ES_TARGET_BITS[target]);
  });

  test('es5 는 정의된 feature 를 빠짐없이 set 한다', () => {
    // es5 = "ES5 이후 도입된 모든 feature 가 미지원" 이므로 set 비트 수 = feature 수.
    // FEATURES 배열에 빠진 항목이 있으면 여기서 어긋난다.
    expect(popcount(ES_TARGET_BITS.es5)).toBe(FEATURES.length);
  });

  test('엔진 매트릭스 환산이 ES 타겟 환산과 같은 폭을 쓴다', () => {
    // 아주 낮은 엔진 = ES5 수준이므로 feature 대부분이 미지원으로 나와야 한다.
    // ⚠️ 이 테스트는 "int32 절단" 을 잡지 못한다 — feature 가 31개(비트 0-30)뿐이라
    //    `1 << i` 가 아직 넘치지 않기 때문이다(변이로 확인). 절단은 테스트가 아니라
    //    BigInt 누산으로 구조적으로 막았다(compat-engines.ts). 여기서는 환산 결과가
    //    ES5 비트집합의 부분집합인지만 본다.
    const bits = computeUnsupportedFromEngines([{ engine: 'chrome', major: 1, minor: 0 }]);
    expect(Number.isSafeInteger(bits)).toBe(true);
    expect(BigInt(bits) & ~BigInt(ES_TARGET_BITS.es5)).toBe(0n);
  });
});
