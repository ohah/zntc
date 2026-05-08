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

describe('엣지 케이스 + 조합 보강: minify identifiers', () => {
  let fixture: EdgeCombinationFixture;

  beforeAll(() => {
    fixture = createEdgeCombinationFixture();
  });

  afterAll(() => fixture.cleanup());

  test('minifyIdentifiers: for-in LHS 변수가 올바르게 리네이밍됨', () => {
    writeFileSync(
      join(fixture.dir, 'forin.js'),
      'var myObj = { a: 1 };\nvar myKey;\nfor (myKey in myObj) { console.log(myKey); }\nexport var result = myKey;',
    );
    const result = buildSync({
      entryPoints: [join(fixture.dir, 'forin.js')],
      format: 'esm',
      minifyIdentifiers: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('myKey');
    expect(result.outputFiles[0].text).not.toContain('myObj');
  });

  test('minifyIdentifiers: 함수 내부 var hoisting', () => {
    writeFileSync(
      join(fixture.dir, 'hoist.js'),
      'export default (function() { console.log(longName); var longName = 42; return longName; })();',
    );
    const result = buildSync({
      entryPoints: [join(fixture.dir, 'hoist.js')],
      format: 'esm',
      minifyIdentifiers: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('longName');
  });
});
