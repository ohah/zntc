import {
  afterAll,
  beforeAll,
  build,
  createOptionCombinationFixture,
  describe,
  expect,
  join,
  removeOptionCombinationFixture,
  test,
  writeFileSync,
} from '../helpers';

describe('옵션 조합 통합 테스트 - core options - splitting', () => {
  let dir: string;

  beforeAll(() => {
    dir = createOptionCombinationFixture();
  });

  afterAll(() => {
    removeOptionCombinationFixture(dir);
  });

  test('splitting + entryNames + chunkNames 조합', async () => {
    writeFileSync(join(dir, 'dyn-entry.ts'), 'export const lazy = () => import("./lib");');
    const result = await build({
      entryPoints: [join(dir, 'dyn-entry.ts')],
      splitting: true,
      entryNames: '[name]',
      chunkNames: 'chunks/[name]-[hash]',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
  });

  // 회귀 가드: splitting + 두 entry 가 같은 shared CSS 를 import 할 때 한
  // 청크만 owner 가 되고 다른 청크 `.css` 에서는 shared 규칙이 누락되던
  // single-owner dedup 버그. esbuild/webpack 처럼 도달 가능한 모든 청크에
  // shared CSS 를 인라인 복제(cascade 보존, 페이지 독립 로드 가능)해야 한다.
  // 동적 청크도 자기가 import 한 CSS 가 별도 `.css` 로 emit 되고, JS 청크에
  // `<link>` prologue 가 주입돼야 단독 로드 시 스타일 적용된다.
  test('splitting + CSS — shared CSS 가 도달 모든 청크에 인라인 + 동적 청크도 자기 CSS 가짐', async () => {
    writeFileSync(join(dir, 'a.css'), '.a { color: red; }\n');
    writeFileSync(join(dir, 'b.css'), '.b { color: blue; }\n');
    writeFileSync(join(dir, 'common.css'), '.common { font-size: 14px; }\n');
    writeFileSync(
      join(dir, 'a-entry.ts'),
      'import "./a.css";\nimport "./common.css";\nimport("./dyn-a").then(m => m.run());\nexport const a = 1;\n',
    );
    writeFileSync(
      join(dir, 'b-entry.ts'),
      'import "./b.css";\nimport "./common.css";\nexport const b = 2;\n',
    );
    writeFileSync(
      join(dir, 'dyn-a.ts'),
      'import "./common.css";\nexport function run() { return "dyn"; }\n',
    );

    const result = await build({
      entryPoints: [join(dir, 'a-entry.ts'), join(dir, 'b-entry.ts')],
      splitting: true,
      entryNames: '[name]',
      chunkNames: '[name]',
    });
    expect(result.errors.length).toBe(0);

    const css = result.outputFiles.filter((f) => f.path.endsWith('.css'));
    const js = result.outputFiles.filter((f) => f.path.endsWith('.js'));

    const findCss = (stem: string) =>
      css.find((f) => {
        const base = f.path.split(/[\\/]/).pop() ?? '';
        return base.startsWith(stem) && base.endsWith('.css');
      });
    const findJs = (stem: string) =>
      js.find((f) => {
        const base = f.path.split(/[\\/]/).pop() ?? '';
        return base.startsWith(stem) && base.endsWith('.js');
      });

    const aCss = findCss('a-entry');
    const bCss = findCss('b-entry');
    const dynCss = findCss('dyn-a');
    const dynJs = findJs('dyn-a');

    // 각 entry CSS 자체는 있어야(기존 동작)
    expect(aCss).toBeDefined();
    expect(bCss).toBeDefined();

    // ★ 회귀 가드 1: shared CSS(.common) 가 b 청크에도 인라인돼야 한다.
    // 버그 시: a 가 min-rank owner 라 b.css 에 .common 누락 → b 페이지에서
    // .common 미적용. 복제(multi-owner) 적용 시 양쪽 모두 포함.
    expect(aCss!.text).toContain('.common');
    expect(bCss!.text).toContain('.common');

    // ★ 회귀 가드 2: 동적 청크 dyn-a 가 자기 .css 를 가져야 한다.
    // 버그 시: dyn-a 는 common 의 owner 가 아니라 청크 CSS 자체가 emit 되지
    // 않음 → dyn-a 단독 진입 시 스타일 미적용. 복제 후엔 dyn-a.css 도 emit.
    expect(dynCss).toBeDefined();
    expect(dynCss!.text).toContain('.common');

    // ★ 회귀 가드 3: 동적 청크 JS 에 `<link>` prologue(런타임 CSS 로더)가
    // 주입돼야 동적 import 시 자기 CSS 가 로드된다. emitter 가 chunk_css_hrefs
    // 를 동적 청크까지 채워야 한다(엔트리뿐 아니라).
    expect(dynJs).toBeDefined();
    expect(dynJs!.text).toMatch(/document\.createElement\(["']link["']\)/);
    // 그리고 prologue 의 *정확한* URL 토큰이 dyn-a 자체 CSS basename 을
    // 가리켜야 한다. 단순 substring(예: 'dyn-a') 은 chunk header/주석/모듈
    // path 에도 등장해 prologue href 오류를 잡지 못한다(tautology). prologue
    // 는 `new URL("./<basename>",import.meta.url)` 형태이므로 그대로 검증.
    const dynCssFullBase = dynCss!.path.split(/[\\/]/).pop() ?? '';
    expect(dynJs!.text).toContain(`new URL("./${dynCssFullBase}",import.meta.url)`);
  });
});
