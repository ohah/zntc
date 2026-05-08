import {
  afterAll,
  beforeAll,
  buildSync,
  describe,
  expect,
  join,
  test,
  writeFileSync,
} from '../helpers';
import { createEdgeCombinationFixture, type EdgeCombinationFixture } from './fixture';

describe('엣지 케이스 + 조합 보강: errors and empty input', () => {
  let fixture: EdgeCombinationFixture;

  beforeAll(() => {
    fixture = createEdgeCombinationFixture();
  });

  afterAll(() => fixture.cleanup());

  test('존재하지 않는 파일 → 에러', () => {
    const result = buildSync({ entryPoints: [join(fixture.dir, 'nonexistent.ts')] });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test('빈 파일 → 정상 빌드', () => {
    writeFileSync(join(fixture.dir, 'empty.ts'), '');
    const result = buildSync({ entryPoints: [join(fixture.dir, 'empty.ts')] });
    expect(result.errors.length).toBe(0);
  });
});
