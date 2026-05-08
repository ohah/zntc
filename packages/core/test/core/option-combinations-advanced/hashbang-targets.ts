import { describe, expect, test, transpile } from '../helpers';

describe('@zntc/core 옵션 조합 심화 - hashbang and targets', () => {
  test('hashbang + minify', () => {
    const result = transpile(
      '#!/usr/bin/env node\nconst longVariableName = 42;\nconsole.log(longVariableName);',
      {
        minify: true,
        target: 'es2023',
      },
    );
    expect(result.code).toContain('#!/usr/bin/env node');
    expect(result.code.length).toBeLessThan(80);
  });

  test('hashbang + sourcemap + es2022 (hashbang 제거됨)', () => {
    const result = transpile('#!/usr/bin/env node\nconst x = 1;', {
      sourcemap: true,
      target: 'es2022',
    });
    expect(result.code).not.toContain('#!');
    expect(result.map).toBeDefined();
  });

  test('transpile: 모든 ES 타겟 순회 (es5~esnext)', () => {
    const targets = [
      'es5',
      'es2015',
      'es2016',
      'es2017',
      'es2018',
      'es2019',
      'es2020',
      'es2021',
      'es2022',
      'es2023',
      'es2024',
      'es2025',
      'esnext',
    ] as const;
    for (const target of targets) {
      const result = transpile('const x = () => 1;', { target });
      expect(result.code.length).toBeGreaterThan(0);
      if (target === 'es5') {
        expect(result.code).not.toContain('=>');
      } else {
        expect(result.code).toContain('=>');
      }
    }
  });
});
