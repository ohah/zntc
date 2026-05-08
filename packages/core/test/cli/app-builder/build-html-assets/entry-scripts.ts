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
});
