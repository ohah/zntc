import {
  afterAll,
  beforeAll,
  build,
  createOptionCombinationFixture,
  describe,
  expect,
  join,
  mkdirSync,
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

  // 회귀 가드: 두 entry 가 같은 stem(예: pages/a/index.tsx + pages/b/index.tsx)
  // 일 때 chunkNames='[name]' 기본 패턴이 두 청크 모두 'index' 로 만들어 CSS
  // 출력 경로 'index.css' 가 충돌 → writeFileSync last-write-wins 로 한쪽 CSS
  // 가 silent 손실되던 pre-existing 버그(multi-owner 화 이후 표면 확대).
  // fix 후: 충돌이 발생하는 청크 그룹 안에서만 content-hash disambiguator 가
  // 자동 부여돼 둘 다 보존된다(같은 stem 그룹 밖의 청크는 안정 파일명 유지).
  test('splitting + CSS — 두 entry 동일 stem 시 CSS path 충돌 회피(자동 hash)', async () => {
    mkdirSync(join(dir, 'pages-a'), { recursive: true });
    mkdirSync(join(dir, 'pages-b'), { recursive: true });
    writeFileSync(
      join(dir, 'pages-a', 'index.ts'),
      'import "./styles.css";\nexport const a = 1;\n',
    );
    writeFileSync(join(dir, 'pages-a', 'styles.css'), '.page-a { color: red; }\n');
    writeFileSync(
      join(dir, 'pages-b', 'index.ts'),
      'import "./styles.css";\nexport const b = 2;\n',
    );
    writeFileSync(join(dir, 'pages-b', 'styles.css'), '.page-b { color: blue; }\n');

    const result = await build({
      entryPoints: [join(dir, 'pages-a', 'index.ts'), join(dir, 'pages-b', 'index.ts')],
      splitting: true,
      entryNames: '[name]',
      chunkNames: '[name]',
      // cssNames 는 기본('[name]') — 의도적으로 충돌 조건을 만든다.
    });
    expect(result.errors.length).toBe(0);

    const css = result.outputFiles.filter((f) => f.path.endsWith('.css'));
    const js = result.outputFiles.filter((f) => f.path.endsWith('.js'));
    // 두 entry 의 CSS 가 모두 outputFiles 에 보존돼야 한다(충돌 silent 손실 금지).
    const aCss = css.find((c) => c.text.includes('.page-a'));
    const bCss = css.find((c) => c.text.includes('.page-b'));
    expect(aCss).toBeDefined();
    expect(bCss).toBeDefined();

    // 그리고 *서로 다른* path 여야 한다(같은 path 면 디스크 쓰기 시 last-wins).
    expect(aCss!.path).not.toBe(bCss!.path);

    // outputFiles 안에 중복 path 가 없어야 한다(전반적 invariant).
    const cssPathSet = new Set(css.map((c) => c.path));
    expect(cssPathSet.size).toBe(css.length);

    // ★ prologue href 정합: 각 entry JS 의 link prologue 가 *자기* 청크의
    // disambiguated CSS basename 을 가리켜야 한다(엉뚱한 청크 CSS 참조 시 cascade
    // 깨짐 + 404 가능). 두 entry 모두 같은 stem 'index' 이므로 JS path 만으론
    // 구별 불가 → 자기 모듈 본문 마커 (transformer 후 'const a = 1' / 'const b = 2'
    // + 'export { a }' / 'export { b }') 로 식별. multi-owner 정책상 entry JS
    // 청크는 자기 CSS link 를 가진다.
    const aJs = js.find((j) => j.text.includes('const a = 1'));
    const bJs = js.find((j) => j.text.includes('const b = 2'));
    expect(aJs).toBeDefined();
    expect(bJs).toBeDefined();
    const aCssBase = aCss!.path.split(/[\\/]/).pop()!;
    const bCssBase = bCss!.path.split(/[\\/]/).pop()!;
    expect(aJs!.text).toContain(`new URL("./${aCssBase}",import.meta.url)`);
    expect(bJs!.text).toContain(`new URL("./${bCssBase}",import.meta.url)`);
    // 그리고 cross-reference 가 *없어야* 한다 — aJs 에 bCss basename, bJs 에
    // aCss basename 이 들어가면 disambiguator 가 잘못된 그룹을 매핑한 것.
    expect(aJs!.text).not.toContain(bCssBase);
    expect(bJs!.text).not.toContain(aCssBase);
  });

  // 회귀 가드: disambiguator 결정성 — 같은 input 두 번 빌드해도 동일한 path
  // 가 나와야 한다(content-hash 기반이라 결정적이어야 함). HashMap 순회 순서
  // 등으로 비결정성이 새어들면 CI 가 떨어지거나 CDN 캐시 히트율이 무너진다.
  test('splitting + CSS — disambiguator 결과는 결정적(두 번 빌드 동일 path)', async () => {
    mkdirSync(join(dir, 'det-a'), { recursive: true });
    mkdirSync(join(dir, 'det-b'), { recursive: true });
    writeFileSync(join(dir, 'det-a', 'index.ts'), 'import "./s.css";\nexport const a = 1;\n');
    writeFileSync(join(dir, 'det-a', 's.css'), '.det-a { color: red; }\n');
    writeFileSync(join(dir, 'det-b', 'index.ts'), 'import "./s.css";\nexport const b = 2;\n');
    writeFileSync(join(dir, 'det-b', 's.css'), '.det-b { color: blue; }\n');

    const opts = {
      entryPoints: [join(dir, 'det-a', 'index.ts'), join(dir, 'det-b', 'index.ts')],
      splitting: true,
      entryNames: '[name]',
      chunkNames: '[name]',
    };
    const r1 = await build(opts);
    const r2 = await build(opts);
    expect(r1.errors.length).toBe(0);
    expect(r2.errors.length).toBe(0);

    const pickCssByMarker = (r: typeof r1, marker: string) =>
      r.outputFiles.find((f) => f.path.endsWith('.css') && f.text.includes(marker))!.path;
    expect(pickCssByMarker(r1, '.det-a')).toBe(pickCssByMarker(r2, '.det-a'));
    expect(pickCssByMarker(r1, '.det-b')).toBe(pickCssByMarker(r2, '.det-b'));
  });
});
