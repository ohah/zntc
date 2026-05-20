import { describe, expect, test } from 'bun:test';

import {
  createStyledComponentsNativePlugin,
  disableStyledComponentsNativeDomProbe,
  STYLED_COMPONENTS_NATIVE_PATH_RE,
} from './styled-components-native.ts';

describe('styled-components/native plugin', () => {
  test('RN 0.85 DOM shim 에서 native entry 의 browser sheet 감지를 비활성화한다', () => {
    const code =
      'var E="undefined"!=typeof window&&"HTMLElement"in window,A=Boolean(process.env.X);';

    expect(disableStyledComponentsNativeDomProbe(code)).toBe(
      'var E=false,A=Boolean(process.env.X);',
    );
  });

  test('공백이 있는 동일 조건식도 비활성화한다', () => {
    const code = 'const shouldUseDOM = typeof window !== "undefined" && "HTMLElement" in window;';

    expect(disableStyledComponentsNativeDomProbe(code)).toBe('const shouldUseDOM = false;');
  });

  test('styled-components/native 배포 파일만 대상으로 한다', () => {
    expect(
      STYLED_COMPONENTS_NATIVE_PATH_RE.test(
        '/repo/node_modules/styled-components/native/dist/styled-components.native.cjs.js',
      ),
    ).toBe(true);
    expect(
      STYLED_COMPONENTS_NATIVE_PATH_RE.test(
        '/repo/node_modules/styled-components/native/dist/styled-components.native.esm.js',
      ),
    ).toBe(true);
    expect(
      STYLED_COMPONENTS_NATIVE_PATH_RE.test(
        '/repo/node_modules/styled-components/dist/styled-components.cjs.js',
      ),
    ).toBe(false);
  });

  test('onTransform 에서 변경된 코드만 반환한다', () => {
    let filter: RegExp | null = null;
    let transform: ((args: { code: string; path: string }) => { code: string } | null) | null =
      null;

    createStyledComponentsNativePlugin().setup({
      onTransform(options, callback) {
        filter = options.filter;
        transform = callback;
      },
      onResolve() {},
      onLoad() {},
      onResolveContext() {},
      onRenderChunk() {},
      onGenerateBundle() {},
      onBuildStart() {},
      onBuildEnd() {},
    });

    const path = '/repo/node_modules/styled-components/native/dist/styled-components.native.cjs.js';
    expect(filter?.test(path)).toBe(true);
    expect(
      transform?.({ path, code: 'var E="undefined"!=typeof window&&"HTMLElement"in window;' }),
    ).toEqual({ code: 'var E=false;' });
    expect(transform?.({ path, code: 'var E=true;' })).toBe(null);
  });
});
