// RN-specific 상수 + helper. preset / plugins 가 공용. NAPI / subprocess 양쪽
// caller 가 require resolve 시 fallback 체인 (rn-get-polyfills → @react-native/js-polyfills)
// 을 일관되게 사용 — RN 0.73 이전/이후 둘 다 호환.

import { createRequire } from 'node:module';

const requireFromCli = createRequire(import.meta.url);

/** `require.resolve` with try/catch — 미해결 시 null. caller 가 fallback chain 구성. */
export function tryResolve(specifier: string, fromDir: string): string | null {
  try {
    return requireFromCli.resolve(specifier, { paths: [fromDir] });
  } catch {
    return null;
  }
}

/**
 * RN polyfill paths (console.js, error-guard.js 등) resolve.
 * - 1순위: `react-native/rn-get-polyfills` (RN 0.73+)
 * - 2순위: `@react-native/js-polyfills` (legacy)
 * 둘 다 미설치 시 console.warn + 빈 배열 반환 — caller 는 graceful skip.
 */
export function resolveRnPolyfills(projectRoot: string): string[] {
  const candidates = ['react-native/rn-get-polyfills', '@react-native/js-polyfills'];
  for (const candidate of candidates) {
    const resolved = tryResolve(candidate, projectRoot);
    if (resolved) {
      try {
        return (requireFromCli(resolved) as () => string[])();
      } catch {
        continue;
      }
    }
  }
  console.warn('[zts] Could not resolve RN polyfills, skipping');
  return [];
}

/**
 * RN reserved global identifiers (RN 0.83 기준 — minor 마다 변할 수 있어 audit 필요).
 * `polyfillGlobal()` 로 등록되는 native global — scope hoisting 시 shadowing 회피.
 */
export const RN_GLOBAL_IDENTIFIERS = [
  // polyfillPromise
  'Promise',
  // setUpRegeneratorRuntime
  'regeneratorRuntime',
  // setUpXHR
  'XMLHttpRequest',
  'FormData',
  'fetch',
  'Headers',
  'Request',
  'Response',
  'WebSocket',
  'Blob',
  'File',
  'FileReader',
  'URL',
  'URLSearchParams',
  'AbortController',
  'AbortSignal',
  // setUpTimers
  'queueMicrotask',
  'setImmediate',
  'clearImmediate',
  'requestIdleCallback',
  'cancelIdleCallback',
  'setTimeout',
  'clearTimeout',
  'setInterval',
  'clearInterval',
  'requestAnimationFrame',
  'cancelAnimationFrame',
  // setUpDOM
  'DOMRect',
  'DOMRectReadOnly',
  'DOMRectList',
  'HTMLCollection',
  'NodeList',
  'Node',
  'Document',
  'CharacterData',
  'Text',
  'Element',
  'HTMLElement',
  // setUpIntersectionObserver
  'IntersectionObserver',
  // setUpMutationObserver
  'MutationObserver',
  'MutationRecord',
  // setUpPerformanceModern
  'EventCounts',
  'Performance',
  'PerformanceEntry',
  'PerformanceEventTiming',
  'PerformanceLongTaskTiming',
  'PerformanceMark',
  'PerformanceMeasure',
  'PerformanceObserver',
  'PerformanceObserverEntryList',
  'PerformanceResourceTiming',
  'TaskAttributionTiming',
] as const;
