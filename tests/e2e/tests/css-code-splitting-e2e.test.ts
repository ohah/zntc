import { test, expect } from '@playwright/test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { serve, closeServer } from './serve';

/**
 * CSS 코드스플리팅 런타임 E2E — 동적 import 된 청크가 자기 CSS 를
 * 런타임 `<link>` 로 주입하고, 그 스타일이 실제 브라우저에서 적용되는지
 * computed style 로 검증한다 (#3321 P0-3).
 *
 * 통합 테스트(bun test)는 출력 문자열까지만 본다 — 본 테스트는 실제
 * 크롬에서 dynamic import → link 주입 → stylesheet 적용을 끝까지 확인.
 */
const ZNTC_BIN = resolve(__dirname, '../../../zig-out/bin/zntc');

const FIXTURE: Record<string, string> = {
  'index.ts': `
const box = document.createElement('div');
box.setAttribute('data-testid', 'box');
box.textContent = 'hello';
document.body.appendChild(box);
import('./route').then((m) => {
  m.mark();
  (window as any).__routeLoaded = true;
});
`,
  'route.ts': `
import './route.css';
export function mark() {
  document.querySelector('[data-testid="box"]')!.classList.add('themed');
}
`,
  // 의도적으로 흔치 않은 색 → 기본값과 확실히 구분
  'route.css': `.themed { color: rgb(1, 2, 3); }`,
};

test('동적 청크의 CSS 가 런타임 <link> 주입으로 실제 적용된다', async ({ page }) => {
  const dir = await mkdtemp(join(tmpdir(), 'zntc-css-split-e2e-'));
  try {
    for (const [name, content] of Object.entries(FIXTURE)) {
      await writeFile(join(dir, name), content);
    }
    const dist = join(dir, 'dist');
    await mkdir(dist, { recursive: true });

    const build = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(dir, 'index.ts'),
        '--splitting',
        '--outdir',
        dist,
        '--entry-names=[name]',
        '--format=esm',
        '--platform=browser',
      ],
      { stdio: 'pipe', timeout: 15000 },
    );
    expect(build.status, `ZNTC build failed: ${build.stderr?.toString().slice(0, 400)}`).toBe(0);

    await writeFile(
      join(dist, 'index.html'),
      `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body><script type="module" src="./index.js"></script></body></html>`,
    );

    const { server, port } = await serve(dist);
    try {
      const errors: string[] = [];
      page.on('pageerror', (e) => errors.push(e.message));

      await page.goto(`http://localhost:${port}/`);
      await page.waitForFunction(() => (window as any).__routeLoaded === true, {
        timeout: 5000,
      });

      // 동적 청크가 주입한 stylesheet <link> 가 head 에 존재
      const hrefs = await page.evaluate(() =>
        [...document.querySelectorAll('link[rel="stylesheet"]')].map((l) =>
          (l as HTMLLinkElement).getAttribute('href'),
        ),
      );
      expect(hrefs.some((h) => !!h && h.endsWith('.css'))).toBe(true);

      // 그 stylesheet 가 실제로 로드·적용되어 computed style 이 바뀜
      const color = await page.evaluate(() => {
        const el = document.querySelector('[data-testid="box"]')!;
        return getComputedStyle(el).color;
      });
      expect(color).toBe('rgb(1, 2, 3)');

      expect(errors, `browser errors: ${errors.join(', ')}`).toHaveLength(0);
    } finally {
      await closeServer(server);
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
