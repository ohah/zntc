import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from './helpers';

describe('CLI: Vite-style app builder > build HTML/assets', () => {
  test('build injects modulepreload links for static split chunks', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-modulepreload-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        '<script type="module" src="/src/admin.ts"></script>',
        '<script type="module" src="/src/client.ts"></script>',
      ].join(''),
    );
    writeFileSync(
      join(dir, 'src', 'admin.ts'),
      'import { shared } from "./shared"; console.log("admin", shared);',
    );
    writeFileSync(
      join(dir, 'src', 'client.ts'),
      'import { shared } from "./shared"; console.log("client", shared);',
    );
    writeFileSync(join(dir, 'src', 'shared.ts'), 'export const shared = "shared";');

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir, '--base', '/app/'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toMatch(/<link rel="modulepreload" href="\/app\/chunk-[a-f0-9]+\.js">/);
    const scripts = html.match(/<script[^>]+src="([^"]+)"/g) ?? [];
    expect(scripts.length).toBe(2);
    expect(scripts[0]).toMatch(/\/app\/admin-[a-f0-9]+\.js/);
    expect(scripts[1]).toMatch(/\/app\/client-[a-f0-9]+\.js/);
    rmSync(dir, { recursive: true, force: true });
  });

  test('modulepreload deduplicates shared chunk across multiple entries', () => {
    // 여러 entry 가 같은 shared chunk 를 import 하면 modulepreload 는 entry 마다 중복
    // 추가하지 말고 단 1회만 주입되어야 한다 (`appendModulePreloadImports` 의 seen set
    // 동작 검증). ZNTC 코드 분할은 동일 reachability mask 모듈을 한 chunk 로 머지하므로
    // 이 setup 에서는 1개의 shared chunk 만 생긴다.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-modulepreload-dedup-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        '<script type="module" src="/src/page-a.ts"></script>',
        '<script type="module" src="/src/page-b.ts"></script>',
      ].join(''),
    );
    writeFileSync(join(dir, 'src', 'shared.ts'), 'export const s = "shared";');
    writeFileSync(
      join(dir, 'src', 'page-a.ts'),
      'import { s } from "./shared"; console.log("a", s);',
    );
    writeFileSync(
      join(dir, 'src', 'page-b.ts'),
      'import { s } from "./shared"; console.log("b", s);',
    );

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const preloadHrefs = [...html.matchAll(/<link rel="modulepreload" href="([^"]+)">/g)].map(
      (m) => m[1],
    );
    expect(preloadHrefs.length).toBeGreaterThanOrEqual(1);
    expect(new Set(preloadHrefs).size).toBe(preloadHrefs.length);
    // shared chunk 만 modulepreload 대상이고 entry chunk 자신은 포함되지 않아야 한다.
    const scripts = [...html.matchAll(/<script[^>]+src="([^"]+)"/g)].map((m) => m[1]);
    for (const href of preloadHrefs) {
      expect(scripts).not.toContain(href);
    }
    rmSync(dir, { recursive: true, force: true });
  });

  test('multiple module scripts each map to their own entry output', () => {
    // Entry chunk 들은 emitter 내부에서 exec_order(=DFS post-order) 로 정렬되어
    // 출력되므로, html 의 <script> 순서와 outputs 순서가 항상 일치한다고 가정하면
    // 깨질 수 있다. build.zig 는 entry path → output 을 module_ids 로 매칭하므로
    // 여기서는 alphabetical 역순/공유 의존성 등으로 자연스럽게 정렬을 흔들면서도
    // 각 <script> 가 자기 entry 의 hashed output 으로 정확히 rewrite 되는지 확인한다.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-entry-mapping-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        // 알파벳 역순 (zeta, alpha) — DFS exec_index 와 무관하게 src 가 자기 chunk 로 매핑되어야 함.
        '<script type="module" src="/src/zeta.ts"></script>',
        '<script type="module" src="/src/alpha.ts"></script>',
      ].join(''),
    );
    writeFileSync(join(dir, 'src', 'shared.ts'), 'export const s = "s";');
    writeFileSync(
      join(dir, 'src', 'alpha.ts'),
      'import { s } from "./shared"; console.log("ALPHA", s);',
    );
    writeFileSync(
      join(dir, 'src', 'zeta.ts'),
      'import { s } from "./shared"; console.log("ZETA", s);',
    );

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scripts = [...html.matchAll(/<script[^>]+src="([^"]+)"/g)].map((m) => m[1]);
    expect(scripts.length).toBe(2);
    expect(scripts[0]).toMatch(/\/zeta-[a-f0-9]+\.js$/);
    expect(scripts[1]).toMatch(/\/alpha-[a-f0-9]+\.js$/);
    // 각 hashed output 의 실제 내용도 자기 entry 의 console.log 를 포함해야 함.
    const zetaPath = join(outdir, scripts[0].replace(/^\//, ''));
    const alphaPath = join(outdir, scripts[1].replace(/^\//, ''));
    expect(readFileSync(zetaPath, 'utf8')).toContain('ZETA');
    expect(readFileSync(alphaPath, 'utf8')).toContain('ALPHA');
    rmSync(dir, { recursive: true, force: true });
  });

  test('build rewrites stylesheet url assets and HTML assets with query/hash', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-assets-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        '<link rel="stylesheet" href="/src/style.css?v=1">',
        '<img src="/src/logo.png?raw#x">',
        '<script type="module" src="/src/main.ts"></script>',
      ].join(''),
    );
    writeFileSync(join(dir, 'src', 'main.ts'), "console.log('assets');");
    writeFileSync(join(dir, 'src', 'style.css'), ".hero{background:url('./bg.png?v=2#hash')}");
    writeFileSync(join(dir, 'src', 'bg.png'), 'bg');
    writeFileSync(join(dir, 'src', 'logo.png'), 'logo');

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir, '--base', '/app/'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);

    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    // stylesheet source 의 root-기준 relative path 가 link href 에 보존된다.
    expect(html).toContain('href="/app/src/style.css?v=1"');
    expect(html).toContain('src="/app/logo.png?raw#x"');
    expect(readFileSync(join(outdir, 'src', 'style.css'), 'utf8')).toContain(
      'url("/app/bg.png?v=2#hash")',
    );
    expect(existsSync(join(outdir, 'bg.png'))).toBe(true);
    expect(existsSync(join(outdir, 'logo.png'))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });
});
