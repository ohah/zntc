import {
  afterAll,
  beforeAll,
  buildSync,
  describe,
  expect,
  join,
  runBundleStdout,
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

  test('minifyIdentifiers: re-export 경유 top-level 이름을 함수 local 이름과 충돌시키지 않음', async () => {
    writeFileSync(
      join(fixture.dir, 'colors.ts'),
      'export const COLORS = { white: "#fff", black: "#000" };\n',
    );
    writeFileSync(join(fixture.dir, 'theme.ts'), 'export * from "./colors";\n');
    writeFileSync(join(fixture.dir, 'ui.ts'), 'export * from "./theme";\n');
    writeFileSync(join(fixture.dir, 'intl.ts'), 'export function msg(id) { return id; }\n');
    writeFileSync(
      join(fixture.dir, 'reexport-local-shadow.ts'),
      [
        'import { COLORS } from "./ui";',
        'import { msg } from "./intl";',
        'function render() {',
        '  const local0 = msg("l0");',
        '  const oneIsEnough = msg("local");',
        '  return COLORS.white + oneIsEnough + local0;',
        '}',
        'console.log(render());',
      ].join('\n'),
    );

    const result = buildSync({
      entryPoints: [join(fixture.dir, 'reexport-local-shadow.ts')],
      bundle: true,
      format: 'iife',
      minify: true,
    });

    expect(result.errors.length).toBe(0);
    await expect(runBundleStdout(result.outputFiles[0].text)).resolves.toBe('#ffflocall0');
  });
});
