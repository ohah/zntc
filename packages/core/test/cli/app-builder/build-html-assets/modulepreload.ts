import {
  describe,
  expect,
  join,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

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
});
