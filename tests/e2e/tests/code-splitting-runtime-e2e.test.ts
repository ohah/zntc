import { test, expect } from '@playwright/test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { serve, closeServer } from './serve';

/**
 * 코드스플리팅 런타임 E2E — IIFE splitting 의 동적 청크가 `__zntc_load_chunk`
 * 의 `<script>` 주입으로 실제 크롬에서 로드·실행되고, 실 `Content-Security-
 * Policy: script-src 'nonce-…'` 정책 하에서 zntc 로더가 주입 스크립트에
 * nonce 를 달아 **브라우저가 실제로 허용**하는지 검증한다 (#3318 §8.1 S0).
 *
 * 통합 테스트(bun test)는 Node `document` 스텁(시뮬)으로만 본다 — 본
 * 테스트는 실 브라우저 + 실 CSP 로 그 갭(JS 동적청크 로드·CSP nonce)을
 * 메운다. css-code-splitting-e2e(CSS `<link>`)와 짝.
 */
const ZNTC_BIN = resolve(__dirname, '../../../zig-out/bin/zntc');
const NONCE = 'zntcS0nonce';

const FIXTURE: Record<string, string> = {
  'index.ts': `
const box = document.createElement('div');
box.id = 'box';
box.textContent = 'base';
document.body.appendChild(box);
import('./route').then((m) => { m.mark(); (window as any).__done = true; });
`,
  'route.ts': `export function mark() { document.getElementById('box')!.textContent = 'loaded'; }`,
};

test('IIFE 동적 청크가 실 CSP nonce 정책 하에서 <script> 주입으로 로드·실행', async ({ page }) => {
  const dir = await mkdtemp(join(tmpdir(), 'zntc-cs-runtime-e2e-'));
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
        '--format=iife',
        '--platform=browser',
      ],
      { stdio: 'pipe', timeout: 15000 },
    );
    expect(build.status, `ZNTC build failed: ${build.stderr?.toString().slice(0, 400)}`).toBe(0);

    // 호스트 작성 <script> 는 nonce 부여(CSP 통과), __zntc_nonce 설정 →
    // zntc 동적 로더가 주입하는 route.js <script> 도 같은 nonce 를 받음.
    // 위반 수집 리스너는 <head> inline(동기) — <body> 의 index.js 및 그것이
    // 주입하는 route.js 보다 항상 먼저 등록됨(파싱 순서 보장, 레이스 없음).
    await writeFile(
      join(dist, 'index.html'),
      `<!DOCTYPE html><html><head><meta charset="utf-8">` +
        `<script nonce="${NONCE}">window.__cspViolations=[];` +
        `document.addEventListener('securitypolicyviolation',e=>window.__cspViolations.push(e.violatedDirective+' '+e.blockedURI));` +
        `window.__zntc_nonce=${JSON.stringify(NONCE)};</script>` +
        `</head><body><script nonce="${NONCE}" src="./index.js"></script></body></html>`,
    );

    // 실 CSP: nonce 없는 스크립트는 차단 → zntc 로더가 nonce 를 안 달면
    // route.js 가 CSP 로 막혀 동적 청크가 실행 안 됨(테스트 실패로 드러남).
    const { server, port } = await serve(dist, {
      'Content-Security-Policy': `script-src 'nonce-${NONCE}'`,
    });
    try {
      const errors: string[] = [];
      page.on('pageerror', (e) => errors.push(e.message));
      // 청크가 CSP 로 차단되면 응답 자체가 0건이거나 비-200 — "차단 안 됨 +
      // 실행됨"을 이중 보장(securitypolicyviolation 은 비동기라 그것만으론
      // 늦은 도착을 못 잡음).
      let routeStatus = 0;
      page.on('response', (r) => {
        if (r.url().includes('route')) routeStatus = r.status();
      });

      await page.goto(`http://localhost:${port}/`);
      await page.waitForFunction(() => (window as any).__done === true, { timeout: 5000 });
      // 위반 이벤트 큐가 비도록 2 프레임 settle — 늦게 도착하는 위반을
      // 놓치고 거짓 통과하는 회귀 방지(효율 리뷰 #2).
      await page.evaluate(
        () =>
          new Promise<void>((r) => requestAnimationFrame(() => requestAnimationFrame(() => r()))),
      );

      // 동적 청크 코드가 실 브라우저에서 실행되어 DOM 반영. 엄격한
      // `script-src 'nonce-…'` 하에서 이게 성립한다는 것 자체가 zntc 로더가
      // 주입 <script> 에 올바른 nonce 를 달았다는 결정적 증거 — nonce 미설정/
      // 오설정이면 route.js 가 CSP 로 차단되어 box 가 'base' 로 남고 아래
      // 위반 카운트가 잡힌다. (브라우저는 보안상 적용 후 nonce content
      // attribute 를 비우므로 getAttribute 로는 검증 불가 — 실행 결과로 증명.)
      expect(await page.locator('#box').textContent()).toBe('loaded');

      // route 청크가 실제 200 으로 서빙·로드됨(CSP 차단 시 미발생)
      expect(routeStatus).toBe(200);
      // CSP 위반 0 (nonce 미설정 시 route.js 주입이 여기 잡힘)
      const violations = await page.evaluate(() => (window as any).__cspViolations ?? []);
      expect(violations, `CSP violations: ${JSON.stringify(violations)}`).toHaveLength(0);
      expect(errors, `browser errors: ${errors.join(', ')}`).toHaveLength(0);
    } finally {
      await closeServer(server);
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
