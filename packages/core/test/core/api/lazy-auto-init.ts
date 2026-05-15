import { describe, test, expect } from 'bun:test';

// 일부러 helpers 에서 init()/close() 를 받지 않는다. lazy auto-init 가
// `transpile()` 의 첫 호출에서 addon 을 자동 로드하는지 검증.
import { transpile } from '../../../index';

describe('@zntc/core: lazy auto-init', () => {
  test('init() 명시 호출 없이도 transpile 가 동작', () => {
    const result = transpile('const x: number = 1;', { filename: 'input.ts' });
    expect(result.code).toContain('const x = 1;');
  });
});
