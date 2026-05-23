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
      // 옛 default 시대 시나리오 — cssNames 도 평면 패턴 명시.
      // (PR B-4b sub-2 부터 cssNames default 는 `[dir]/[name]` 으로 변경됐으므로
      // disambiguator 동작 검증 위해 명시적으로 옛 default 옵트인.)
      cssNames: '[name]',
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
      // 옛 default 시대 disambiguator 결정성 검증 — cssNames 도 평면 명시.
      cssNames: '[name]',
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

  // 회귀 가드: splitting:false (=비-splitting / preserve-modules) 모드에서도
  // 두 entry 가 같은 stem 이면 CSS 출력 경로가 충돌 → 한쪽 silent 손실되던
  // pre-existing 버그. splitting:true 경로는 PR #3686 에서 처리됐고, 본 가드
  // 는 비-splitting 경로(`bundler.zig:1879` 의 emitCssBundle 루프) 도 같은
  // disambiguator 정책을 따르는지 검증한다.
  test('splitting:false + CSS — 두 entry 동일 stem 시 CSS path 충돌 회피', async () => {
    mkdirSync(join(dir, 'ns-a'), { recursive: true });
    mkdirSync(join(dir, 'ns-b'), { recursive: true });
    writeFileSync(join(dir, 'ns-a', 'index.ts'), 'import "./s.css";\nconst a = 1;\n');
    writeFileSync(join(dir, 'ns-a', 's.css'), '.ns-a { color: red; }\n');
    writeFileSync(join(dir, 'ns-b', 'index.ts'), 'import "./s.css";\nconst b = 2;\n');
    writeFileSync(join(dir, 'ns-b', 's.css'), '.ns-b { color: blue; }\n');

    const result = await build({
      entryPoints: [join(dir, 'ns-a', 'index.ts'), join(dir, 'ns-b', 'index.ts')],
      splitting: false,
      entryNames: '[name]',
      // 비-splitting disambiguator 검증 — 옛 평면 default 명시.
      cssNames: '[name]',
    });
    expect(result.errors.length).toBe(0);

    const css = result.outputFiles.filter((f) => f.path.endsWith('.css'));
    const aCss = css.find((c) => c.text.includes('.ns-a'));
    const bCss = css.find((c) => c.text.includes('.ns-b'));
    // 두 entry CSS 모두 보존(충돌 silent 손실 금지).
    expect(aCss).toBeDefined();
    expect(bCss).toBeDefined();
    // 서로 다른 path 여야 한다.
    expect(aCss!.path).not.toBe(bCss!.path);
    // 전체 outputFiles 안에 중복 path 가 없어야 한다(전반적 invariant).
    const cssPathSet = new Set(css.map((c) => c.path));
    expect(cssPathSet.size).toBe(css.length);
  });

  // 회귀 가드: 비-splitting 모드의 disambiguator 결정성 — 같은 input 두 번
  // 빌드해도 동일한 disambiguated path 가 나와야 한다(splitting 경로의 결정성
  // 가드와 같은 invariant 를 비-splitting 경로에도 적용).
  test('splitting:false + CSS — disambiguator 결과는 결정적(두 번 빌드 동일 path)', async () => {
    mkdirSync(join(dir, 'nsd-a'), { recursive: true });
    mkdirSync(join(dir, 'nsd-b'), { recursive: true });
    writeFileSync(join(dir, 'nsd-a', 'index.ts'), 'import "./s.css";\nconst a = 1;\n');
    writeFileSync(join(dir, 'nsd-a', 's.css'), '.nsd-a { color: red; }\n');
    writeFileSync(join(dir, 'nsd-b', 'index.ts'), 'import "./s.css";\nconst b = 2;\n');
    writeFileSync(join(dir, 'nsd-b', 's.css'), '.nsd-b { color: blue; }\n');

    const opts = {
      entryPoints: [join(dir, 'nsd-a', 'index.ts'), join(dir, 'nsd-b', 'index.ts')],
      splitting: false,
      entryNames: '[name]',
      // F2 (sub-2 review): cssNames default 변경 후에도 *disambiguator 결정성*
      // 검증 의도 보존을 위해 평면 cssNames 명시.
      cssNames: '[name]',
    };
    const r1 = await build(opts);
    const r2 = await build(opts);
    expect(r1.errors.length).toBe(0);
    expect(r2.errors.length).toBe(0);
    const pickCssByMarker = (r: typeof r1, marker: string) =>
      r.outputFiles.find((f) => f.path.endsWith('.css') && f.text.includes(marker))!.path;
    expect(pickCssByMarker(r1, '.nsd-a')).toBe(pickCssByMarker(r2, '.nsd-a'));
    expect(pickCssByMarker(r1, '.nsd-b')).toBe(pickCssByMarker(r2, '.nsd-b'));
  });

  // PR B-4b sub-2 회귀 가드: default `entryNames` 가 `[dir]/[name]` 이라는
  // semver-major 약속. entryNames 명시 *없이* 두 entry 가 다른 dir 의 같은
  // stem 일 때 자동으로 dir prefix 가 붙어 path collision 회피되어야 한다.
  // (옛 default `[name]` 시대엔 disambiguator 가 처리했고, 새 default 는
  // disambiguator 발현 전에 dir-aware path 로 emit.)
  test('default entryNames — 같은 stem 두 entry 가 [dir]/[name] 으로 자동 unique', async () => {
    mkdirSync(join(dir, 'def-a'), { recursive: true });
    mkdirSync(join(dir, 'def-b'), { recursive: true });
    writeFileSync(join(dir, 'def-a', 'index.ts'), 'const a = 1;\nexport { a };\n');
    writeFileSync(join(dir, 'def-b', 'index.ts'), 'const b = 2;\nexport { b };\n');

    const result = await build({
      // entryNames 명시 *안 함* — default 동작 검증.
      entryPoints: [join(dir, 'def-a', 'index.ts'), join(dir, 'def-b', 'index.ts')],
      splitting: true,
    });
    expect(result.errors.length).toBe(0);

    const js = result.outputFiles.filter((f) => f.path.endsWith('.js'));
    const aJs = js.find((j) => j.text.includes('const a = 1'));
    const bJs = js.find((j) => j.text.includes('const b = 2'));
    expect(aJs).toBeDefined();
    expect(bJs).toBeDefined();
    // 새 default 라 path 가 자동으로 `def-a/index*.js` / `def-b/index*.js`
    // 형태가 되어 collision 없음 (disambiguator hash 부여 없이).
    expect(aJs!.path).not.toBe(bJs!.path);
    const jsPathSet = new Set(js.map((j) => j.path));
    expect(jsPathSet.size).toBe(js.length);
    // 시맨틱 lock (F3 review) — uniqueness 외 entry dir prefix 가 path 에
    // 실제로 포함되는지 강제.
    expect(aJs!.path).toMatch(/def-a\//);
    expect(bJs!.path).toMatch(/def-b\//);
  });

  // PR B-4b sub-2 회귀 가드: default `cssNames` 가 `[dir]/[name]`. entry CSS
  // 도 자동으로 dir prefix → same-stem CSS path collision 자동 회피.
  test('default cssNames — 같은 stem 두 entry 의 CSS 가 [dir]/[name] 으로 자동 unique', async () => {
    mkdirSync(join(dir, 'cdef-a'), { recursive: true });
    mkdirSync(join(dir, 'cdef-b'), { recursive: true });
    writeFileSync(join(dir, 'cdef-a', 'index.ts'), 'import "./s.css";\nconst a = 1;\n');
    writeFileSync(join(dir, 'cdef-a', 's.css'), '.cdef-a { color: red; }\n');
    writeFileSync(join(dir, 'cdef-b', 'index.ts'), 'import "./s.css";\nconst b = 2;\n');
    writeFileSync(join(dir, 'cdef-b', 's.css'), '.cdef-b { color: blue; }\n');

    const result = await build({
      entryPoints: [join(dir, 'cdef-a', 'index.ts'), join(dir, 'cdef-b', 'index.ts')],
      splitting: true,
    });
    expect(result.errors.length).toBe(0);

    const css = result.outputFiles.filter((f) => f.path.endsWith('.css'));
    const aCss = css.find((c) => c.text.includes('.cdef-a'));
    const bCss = css.find((c) => c.text.includes('.cdef-b'));
    expect(aCss).toBeDefined();
    expect(bCss).toBeDefined();
    expect(aCss!.path).not.toBe(bCss!.path);
    // 새 default `[dir]/[name]` semantics 가드 — 단순 uniqueness 가 아닌
    // *entry dir prefix 가 path 에 실제로 포함됨* 검증 (F3 review).
    // 옛 default 로 회귀하면 disambiguator hash 로 unique 해져 위 not.toBe 는
    // 통과하지만 아래 toMatch 는 실패 — 정확한 시맨틱 lock.
    expect(aCss!.path).toMatch(/cdef-a\//);
    expect(bCss!.path).toMatch(/cdef-b\//);
  });

  // PR B-4b sub-2 회귀 가드: 사용자가 명시적으로 `entryNames: '[name]'` opt-out
  // 하면 옛 평면 동작이 그대로. 즉 path 에 entry dir prefix 가 *붙지 않음*
  // (collision 자체는 disambiguator 보호 영역 — 별도 test 가 검증).
  test('entryNames opt-out — `[name]` 명시 시 path 에 dir prefix 안 붙음', async () => {
    mkdirSync(join(dir, 'optout-a'), { recursive: true });
    mkdirSync(join(dir, 'optout-b'), { recursive: true });
    writeFileSync(join(dir, 'optout-a', 'index.ts'), 'const a = 1;\nexport { a };\n');
    writeFileSync(join(dir, 'optout-b', 'index.ts'), 'const b = 2;\nexport { b };\n');

    const result = await build({
      entryPoints: [join(dir, 'optout-a', 'index.ts'), join(dir, 'optout-b', 'index.ts')],
      splitting: true,
      entryNames: '[name]', // 옛 평면 default 옵트인.
    });
    expect(result.errors.length).toBe(0);

    const js = result.outputFiles.filter((f) => f.path.endsWith('.js'));
    // 두 entry JS 모두 outputFiles 에 emit (collision 시 in-memory list 엔
    // 둘 다 유지되고 disk write 단계에서 last-wins — F3 review 강화).
    const aJs = js.find((j) => j.text.includes('const a = 1'));
    const bJs = js.find((j) => j.text.includes('const b = 2'));
    expect(aJs).toBeDefined();
    expect(bJs).toBeDefined();
    // path 가 `<dir>/index.js` 형태가 아니어야 — opt-out 효과.
    expect(aJs!.path).not.toMatch(/optout-[ab]\//);
    expect(bJs!.path).not.toMatch(/optout-[ab]\//);
  });
});
