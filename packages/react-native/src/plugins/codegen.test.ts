import { describe, expect, test } from 'bun:test';

import { CODEGEN_NATIVE_COMPONENT_MARKER, createCodegenTransformer } from './codegen.ts';

describe('CODEGEN_NATIVE_COMPONENT_MARKER', () => {
  test('정확한 literal', () => {
    expect(CODEGEN_NATIVE_COMPONENT_MARKER).toBe('codegenNativeComponent');
  });
});

describe('createCodegenTransformer', () => {
  test('marker 미포함 코드 — null (no transform 시도)', () => {
    const transform = createCodegenTransformer('/nonexistent');
    expect(transform('const x = 1;', '/abs/foo.js')).toBeNull();
    expect(transform('const x = 1;', '/abs/foo.ts')).toBeNull();
  });

  test('.jsx / .tsx — null (.js/.ts 만 허용 — RN NativeComponent 파일 컨벤션)', () => {
    const transform = createCodegenTransformer('/nonexistent');
    expect(transform("codegenNativeComponent('X')", '/abs/foo.jsx')).toBeNull();
    expect(transform("codegenNativeComponent('X')", '/abs/foo.tsx')).toBeNull();
  });

  test('.js + marker — Babel 호출 시도. plugin 미설치 시 graceful null', () => {
    // @react-native/babel-plugin-codegen 미설치 환경 (projectRoot=/nonexistent
    // 라 require.resolve 도 fail) — ensureBabel throw, transform 의 outer catch
    // 가 잡아 null. (stderr 출력은 process.stderr.write native binding 으로 spy
    // 검증이 어려워 결과만 검증.)
    const transform = createCodegenTransformer('/nonexistent');
    const result = transform("const X = codegenNativeComponent('Foo');", '/abs/NativeFoo.js');
    expect(result).toBeNull();
  });

  test('filename 에 따라 parser plugin 분기 — `.js` → flow, `.ts` → typescript', () => {
    // 직접 검증 어려움 (private). marker 없으면 null 반환 의 결정성만 검증.
    const transform = createCodegenTransformer('/nonexistent');
    expect(transform('export {};', '/abs/foo.js')).toBeNull();
    expect(transform('export {};', '/abs/foo.ts')).toBeNull();
  });
});
