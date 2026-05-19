import type { ZntcPlugin } from '@zntc/core';

export const STYLED_COMPONENTS_NATIVE_PATH_RE =
  /(?:^|[/\\])styled-components[/\\]native[/\\]dist[/\\]styled-components\.native\.(?:cjs|esm)\.js$/;

const DOM_PROBE_PATTERNS = [
  /(['"])undefined\1\s*!=\s*typeof\s+window\s*&&\s*(['"])HTMLElement\2\s*in\s+window/g,
  /typeof\s+window\s*!==?\s*(['"])undefined\1\s*&&\s*(['"])HTMLElement\2\s*in\s+window/g,
];

export function disableStyledComponentsNativeDomProbe(code: string): string | null {
  let next = code;
  for (const pattern of DOM_PROBE_PATTERNS) {
    next = next.replace(pattern, 'false');
  }
  return next === code ? null : next;
}

/**
 * RN 0.85 의 setUpDOM 은 `HTMLElement` 를 global/window 에 lazy polyfill 하지만,
 * browser `document` 는 제공하지 않는다. styled-components/native v6 는
 * `"HTMLElement" in window` 만으로 browser sheet 경로를 선택해 module 평가 중
 * `document.querySelectorAll` 을 호출할 수 있으므로 native entry 에서는 DOM 감지를
 * 명시적으로 꺼 둔다.
 */
export function createStyledComponentsNativePlugin(): ZntcPlugin {
  return {
    name: 'zntc:react-native:styled-components-native',
    setup(build) {
      build.onTransform({ filter: STYLED_COMPONENTS_NATIVE_PATH_RE }, (args) => {
        const code = disableStyledComponentsNativeDomProbe(args.code);
        return code ? { code } : null;
      });
    },
  };
}
