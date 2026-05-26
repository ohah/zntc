import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from '../helpers';

describe('CLI: Vite-style app builder > styles > PostCSS', () => {
  test('JS-imported CSS is linked from HTML and processed by PostCSS', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-postcss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div class="card">PostCSS</div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.css"; console.log("css");');
    writeFileSync(
      join(dir, 'src', 'style.css'),
      '.card { color: red; }\n.card { background: white; }\n',
    );
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'zntc-test-postcss', Once(root) { root.append({ selector: '.postcss-ok', nodes: [] }); } },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toContain('rel="stylesheet"');
    expect(html).toContain('href="/main.css"');
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    expect(css).toContain('.postcss-ok');
    rmSync(dir, { recursive: true, force: true });
  });

  // RFC #3833 v3 D1a'' (caller-side pre-warm): 사용자 explicit `plugins: [css({
  // postcss: { plugins: [...override] } })]` 가 buildAppSync 의 sync dispatcher 와
  // 호환 안 되지만, runAppBuild 가 caller-side 에서 옵션 extract 해
  // prepareAppCssPipelineRoot 의 PostCSS 단계에 override 직접 전달 → main thread
  // async pre-warm → tempRoot commit → sync build 가 결과 read. 회귀 가드.
  test('explicit css({postcss}) override via caller-side pre-warm (D1a)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-postcss-override-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div class="card">override</div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.css";');
    writeFileSync(join(dir, 'src', 'style.css'), '.card { color: red; }\n');
    // postcss.config 부재 — 자동 발견 path 가 null 이어야 override path 가 활성화됨.
    // fixture 가 @zntc/web 미설치 → css() 반환과 동등 plain object 직접 정의.
    // caller (runAppBuild) 가 name + __cssOptions sentinel 만 검사 (D1a'' design).
    writeFileSync(
      join(dir, 'zntc.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        '    {',
        "      name: '@zntc/web/css',",
        '      __cssOptions: {',
        '        postcss: {',
        '          plugins: [',
        "            { postcssPlugin: 'override-marker', Once(root) { root.append({ selector: '.override-applied', nodes: [] }); } },",
        '          ],',
        '        },',
        '      },',
        '      setup() {},',
        '    },',
        '  ],',
        '};',
      ].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    // caller-side pre-warm path 도 동일 메시지 출력 (postcss.ts:logPostcssProcessed)
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    expect(css).toContain('.override-applied');
    rmSync(dir, { recursive: true, force: true });
  });

  // D1a'' 의 disabled:true 분기 — 사용자 명시적으로 PostCSS 끄기. postcss.config 가
  // 있어도 자동발견 차단되어야 (extractCssPostcssOverride 가 {plugins:[]} 반환 →
  // prepare 의 length 0 skip).
  test('explicit css({disabled:true}) — auto-discover 차단 (D1a)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-css-disabled-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div class="card">disabled</div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.css";');
    writeFileSync(join(dir, 'src', 'style.css'), '.card { color: red; }\n');
    // postcss.config 있음 — 자동발견 path 가 평소엔 적용되지만 disabled:true 가
    // override path 진입시켜 차단해야.
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'auto-marker', Once(root) { root.append({ selector: '.should-not-appear', nodes: [] }); } },",
        '  ],',
        '};',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'zntc.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { name: '@zntc/web/css', __cssOptions: { disabled: true }, setup() {} },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    // disabled 가 자동발견 차단 → marker 안 나타남
    expect(css).not.toContain('.should-not-appear');
    expect(css).toContain('.card');
    rmSync(dir, { recursive: true, force: true });
  });

  // D1a'' 의 findLast 분기 — user explicit css() 가 default prepend 보다 winner.
  // 본 fixture 는 두 css() 명시 — 마지막 (override marker) 만 적용 확인.
  test('findLast — 마지막 css() 가 winner (default + user override 동시)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-css-findlast-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div class="card">findLast</div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.css";');
    writeFileSync(join(dir, 'src', 'style.css'), '.card { color: red; }\n');
    // 두 css() — 첫 번째 가 default-like (plugins=[]), 마지막 이 user override.
    // findLast 가 마지막 winner → .winner-marker 만 적용, .default-marker 미적용.
    writeFileSync(
      join(dir, 'zntc.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { name: '@zntc/web/css', __cssOptions: { postcss: { plugins: [{ postcssPlugin: 'default-marker', Once(root) { root.append({ selector: '.default-marker', nodes: [] }); } }] } }, setup() {} },",
        "    { name: '@zntc/web/css', __cssOptions: { postcss: { plugins: [{ postcssPlugin: 'winner-marker', Once(root) { root.append({ selector: '.winner-marker', nodes: [] }); } }] } }, setup() {} },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    expect(css).toContain('.winner-marker'); // findLast = 마지막 winner
    expect(css).not.toContain('.default-marker');
    rmSync(dir, { recursive: true, force: true });
  });

  test('Tailwind v4 @tailwindcss/postcss app fixture', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-tailwind-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<main class="text-red-500"><script type="module" src="/src/main.ts"></script></main>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.css";');
    writeFileSync(
      join(dir, 'src', 'style.css'),
      '@import "tailwindcss";\n@source "../index.html";\n',
    );
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      'export default { plugins: { "@tailwindcss/postcss": {} } };\n',
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    expect(css).toContain('.text-red-500');
    expect(css).not.toContain('@import "tailwindcss"');
    rmSync(dir, { recursive: true, force: true });
  });
});
