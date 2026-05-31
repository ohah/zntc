import { describe, test, expect, afterEach } from 'bun:test';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, ZNTC_JS_CLI } from './helpers';

// #4062 PR-B-2: JS dev 서버(`zntc dev`, app 모드)의 lazy on-demand 라우트.
// 게이트 = env `ZNTC_LAZY=1`(실험적). native lazy 프리미티브(#4069/#4070 + #4071 watch parity)
// 위에 JS 서버가 얇게 on-demand 라우팅을 얹는다:
//   ① served index.html 의 `/bundle.js` → watch lazy entry 청크(`__zntc_load_chunk` 포함) alias
//   ② `/<stem>-<8hex>.js` → 그 seed 만 force-parse 한 단발 build() 로 동적 청크 즉석 생성·서빙
// 동적 import 타겟(heavy)은 emit-skip 되어 초기 디스크에 없고, 브라우저가 그 URL 을 요청할 때만 빌드된다.

async function waitForServer(port: number, timeoutMs = 15000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const r = await fetch(`http://localhost:${port}/`);
      if (r.ok || r.status === 404) return;
    } catch {
      // 아직 listen 안 함
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`dev server did not start on port ${port}`);
}

describe('JS dev server lazy on-demand route (#4062 PR-B-2)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  let proc: ReturnType<typeof Bun.spawn> | undefined;

  afterEach(async () => {
    if (proc) {
      proc.kill();
      await proc.exited;
      proc = undefined;
    }
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('ZNTC_LAZY=1 → entry 가 __zntc_load_chunk, heavy 는 on-demand 로만 서빙', async () => {
    const fixture = await createFixture({
      'index.html': `<!doctype html><html><head><meta charset="utf-8"/><title>L</title></head><body><div id="root"></div><script type="module" src="/src/main.ts"></script></body></html>`,
      'src/main.ts': `async function go(){ const m = await import('./heavy'); document.getElementById('root')!.textContent = m.h; }\ngo();`,
      'src/heavy.ts': `export const h = 'HEAVY_LAZY_PRB2';`,
    });
    cleanup = fixture.cleanup;

    // 테스트 파일 간 충돌 회피용 고정-대역 포트(다른 dev-server 테스트와 분리).
    const port = 5390 + Math.floor(Math.random() * 40);
    proc = Bun.spawn({
      cmd: ['bun', ZNTC_JS_CLI, 'dev', fixture.dir, '--port', String(port)],
      env: { ...process.env, ZNTC_LAZY: '1' },
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await waitForServer(port);

    // ① entry alias: served index.html 은 `/bundle.js` 를 참조 → watch lazy entry 청크여야.
    const indexHtml = await (await fetch(`http://localhost:${port}/`)).text();
    expect(indexHtml).toContain('src="/bundle.js"');

    const entryRes = await fetch(`http://localhost:${port}/bundle.js`);
    expect(entryRes.status).toBe(200);
    const entry = await entryRes.text();
    // 동적 청크 로더로 재작성됨(#4071 watch parity 핵심 가드).
    const m = entry.match(/__zntc_load_chunk\("([^"]+)"\)/);
    expect(m).not.toBeNull();
    const chunkUrl = m![1]; // 예: heavy-36529dae.js
    expect(chunkUrl).toMatch(/-[0-9a-f]{8}\.js$/);
    // heavy 본문은 미파싱 seed → entry 에 인라인 안 됨.
    expect(entry).not.toContain('HEAVY_LAZY_PRB2');
    // entry 는 cross-chunk require 로 heavy 모듈을 참조.
    const reqMatch = entry.match(/__zntc_require\("([^"]+)"\)/g) ?? [];
    expect(reqMatch.some((r) => r.includes('heavy'))).toBe(true);

    // ② on-demand 동적 청크: entry 가 참조한 그 URL 을 요청하면 즉석 빌드돼 heavy 본문을 서빙.
    const chunkRes = await fetch(`http://localhost:${port}/${chunkUrl}`);
    expect(chunkRes.status).toBe(200);
    const chunk = await chunkRes.text();
    expect(chunk).toContain('HEAVY_LAZY_PRB2'); // 본문 존재
    expect(chunk).toContain('__zntc_register'); // IIFE registry 로 등록
    // registry 키가 entry 의 require 키와 정합해야 런타임에 resolve 된다(cross-chunk 정합).
    expect(chunk).toMatch(/"heavy\.js":/);

    // 동시 요청 coalesce/직렬화 가드: 같은 청크 5건 동시 요청도 전부 동일 본문 200.
    const burst = await Promise.all(
      Array.from({ length: 5 }, () => fetch(`http://localhost:${port}/${chunkUrl}`)),
    );
    for (const res of burst) {
      expect(res.status).toBe(200);
      expect(await res.text()).toContain('HEAVY_LAZY_PRB2');
    }
  }, 30000);

  test('ZNTC_LAZY 미설정 → 기존 단일 번들(heavy 인라인, on-demand 라우트 비활성)', async () => {
    const fixture = await createFixture({
      'index.html': `<!doctype html><html><head><meta charset="utf-8"/><title>E</title></head><body><div id="root"></div><script type="module" src="/src/main.ts"></script></body></html>`,
      'src/main.ts': `async function go(){ const m = await import('./heavy'); document.getElementById('root')!.textContent = m.h; }\ngo();`,
      'src/heavy.ts': `export const h = 'HEAVY_EAGER_BASELINE';`,
    });
    cleanup = fixture.cleanup;

    const port = 5430 + Math.floor(Math.random() * 40);
    proc = Bun.spawn({
      cmd: ['bun', ZNTC_JS_CLI, 'dev', fixture.dir, '--port', String(port)],
      // ZNTC_LAZY 미설정 — lazy 라우트/옵션 전부 no-op 이어야(단일 파일 dynamic import inline).
      env: { ...process.env, ZNTC_LAZY: '' },
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await waitForServer(port);

    const entryRes = await fetch(`http://localhost:${port}/bundle.js`);
    expect(entryRes.status).toBe(200);
    const entry = await entryRes.text();
    // 기존 dev 기본: 단일 파일이라 동적 import 가 인라인됨 → heavy 본문이 entry 에 존재.
    expect(entry).toContain('HEAVY_EAGER_BASELINE');
    // lazy 로더 미사용.
    expect(entry).not.toContain('__zntc_load_chunk(');
  }, 30000);

  // PR-C-1: rebuild 후에도 lazy on-demand 라우트가 살아있고(seed 맵 갱신) 청크 캐시가 무효화돼
  // 편집된 seed 본문이 반영돼야 한다. onRebuild 가 captureLazyState(event) 로 seed 맵을
  // event.lazySeeds 로 다시 채우고 캐시를 비운다.
  test('ZNTC_LAZY=1 → 파일 편집 rebuild 후 on-demand 청크가 새 본문 반영(캐시 무효화)', async () => {
    const fixture = await createFixture({
      'index.html': `<!doctype html><html><head><meta charset="utf-8"/><title>R</title></head><body><div id="root"></div><script type="module" src="/src/main.ts"></script></body></html>`,
      'src/main.ts': `async function go(){ const m = await import('./heavy'); document.getElementById('root')!.textContent = m.h; }\ngo();`,
      'src/heavy.ts': `export const h = 'HEAVY_V1';`,
    });
    cleanup = fixture.cleanup;

    const port = 5470 + Math.floor(Math.random() * 40);
    proc = Bun.spawn({
      cmd: ['bun', ZNTC_JS_CLI, 'dev', fixture.dir, '--port', String(port)],
      env: { ...process.env, ZNTC_LAZY: '1' },
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await waitForServer(port);

    // heavy 본문이 보이는지(entry 인라인 또는 동적 청크) — entry 를 재조회해 *현재* 청크 URL 로
    // 확인한다. 편집된 seed 는 hash 가 바뀔 수 있으므로(content-hash 승격) URL 을 고정하지 않는다.
    async function heavyBodyVisible(marker: string): Promise<boolean> {
      const e = await (await fetch(`http://localhost:${port}/bundle.js`)).text();
      if (e.includes(marker)) return true; // entry 에 인라인/승격
      const mm = e.match(/__zntc_load_chunk\("([^"]+)"\)/);
      if (!mm) return false;
      const c = await (await fetch(`http://localhost:${port}/${mm[1]}`)).text();
      return c.includes(marker);
    }

    expect(await heavyBodyVisible('HEAVY_V1')).toBe(true); // 초기 = V1

    // heavy 본문 편집 → rebuild. onRebuild 가 lazySeeds 로 seed 맵 갱신 + 청크 캐시 무효화.
    writeFileSync(join(fixture.dir, 'src/heavy.ts'), `export const h = 'HEAVY_V2';`);

    // rebuild 후 새 본문이 (현재 entry 가 가리키는 경로로) 보일 때까지 폴링(최대 ~8s).
    let ok = false;
    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      if (await heavyBodyVisible('HEAVY_V2')) {
        ok = true;
        break;
      }
      await new Promise((r) => setTimeout(r, 200));
    }
    expect(ok).toBe(true); // 캐시 무효화 + seed 맵 갱신 → 편집된 본문이 on-demand 로 반영
    expect(await heavyBodyVisible('HEAVY_V1')).toBe(false); // 옛 본문은 사라짐
  }, 30000);
});
