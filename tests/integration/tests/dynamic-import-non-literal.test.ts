import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { createFixture } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// P1 (#3321): 비-literal 동적 import specifier 는 코드분할 대상이 아니며
// 네이티브 런타임 import() 로 그대로 passthrough — 동작은 불변, 단
// 사용자가 알 수 있도록 warning 진단을 1회 emit 한다.

describe('non-literal dynamic import warning', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('변수 specifier → warning + 원본 import() passthrough(미변형)', async () => {
    const fixture = await createFixture({
      'index.ts': `const name = "./mod";\nexport const p = import(name);\nconsole.log("entry");`,
      'mod.ts': `export default 1;`,
    });
    cleanup = fixture.cleanup;

    const result = await build({ entryPoints: [join(fixture.dir, 'index.ts')] });

    // warning 1회 (메시지에 string literal 안내 포함)
    const w = result.warnings ?? [];
    expect(w.some((d) => /string literal/i.test(d.text ?? ''))).toBe(true);

    // 빌드는 실패하지 않고 출력 생성
    const js = (result.outputFiles ?? []).map((o) => o.text).join('\n');
    expect(js).toContain('entry');
    // 원본 import(name) 이 그대로 남음 (코드분할/래퍼 변형 없음)
    expect(js).toContain('import(name)');
  });

  test('템플릿 리터럴 specifier → warning, 빌드 성공', async () => {
    const fixture = await createFixture({
      'index.ts': `const n = 2;\nexport const p = import(\`./m-\${n}.js\`);\nconsole.log("ok");`,
    });
    cleanup = fixture.cleanup;

    const result = await build({ entryPoints: [join(fixture.dir, 'index.ts')] });
    const w = result.warnings ?? [];
    expect(w.some((d) => /string literal/i.test(d.text ?? ''))).toBe(true);
    const js = (result.outputFiles ?? []).map((o) => o.text).join('\n');
    expect(js).toContain('ok');
  });

  test('회귀: 리터럴 specifier 는 warning 없음(정상 코드분할)', async () => {
    const fixture = await createFixture({
      'index.ts': `export const p = import('./mod');\nconsole.log("lit");`,
      'mod.ts': `export default 1;`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      splitting: true,
    });
    const w = result.warnings ?? [];
    expect(w.some((d) => /string literal/i.test(d.text ?? ''))).toBe(false);
  });
});
