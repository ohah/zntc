// scoped `@jsxImportSource` 번들 회귀 가드 (#3617).
//
// lexer 의 pragma 값 파서가 `@emotion/react` 의 `/` 를 값 종료로 오인해 `@emotion`
// 으로 잘랐고, 그 결과 `@emotion/jsx-runtime` (존재하지 않는 패키지) import 가 생성,
// 번들 시 resolve 실패 → `require()` fallback → 브라우저 `require is not defined` 크래시.
//
// scanner/transformer 유닛 테스트(#3617)는 lexer·transform 레벨만 잡는다. 이 테스트는
// 번들 파이프라인 (transform → resolve → emit) 산출물에 잘린 specifier·bare require 가
// 남지 않는지 end-to-end 로 가드 — "사전 발견" 못 했던 회귀 표면.

import { describe, test, expect, afterEach } from 'bun:test';
import { createFixture, runZntcInDir } from './helpers';
import { join } from 'node:path';
import { readFile } from 'node:fs/promises';

describe('JSX automatic — scoped @jsxImportSource (#3617 회귀)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('scoped 패키지 importSource → 전체 경로 jsx-runtime import (require fallback 없음)', async () => {
    const fx = await createFixture({
      'app.tsx': '/** @jsxImportSource @emotion/react */\nexport const App = () => <p>hi</p>;\n',
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');

    const r = await runZntcInDir(fx.dir, [
      '--bundle',
      'app.tsx',
      '-o',
      out,
      '--platform=browser',
      '--format=esm',
      '--packages=external',
      '--jsx=automatic',
    ]);
    expect(r.exitCode).toBe(0);

    const code = await readFile(out, 'utf8');
    // scoped 전체 경로 보존 (`@emotion/react` + `/jsx-runtime`).
    expect(code).toContain('"@emotion/react/jsx-runtime"');
    // 잘린 잘못된 specifier 미존재.
    expect(code).not.toContain('"@emotion/jsx-runtime"');
    // ESM 번들에 bare `require("@emotion...")` 미존재 — 잘린 specifier resolve 실패 시
    // 나오던 크래시 패턴.
    expect(code).not.toMatch(/\brequire\("@emotion/);
  });

  test('non-scoped importSource (preact) 회귀 없음', async () => {
    const fx = await createFixture({
      'app.tsx': '/** @jsxImportSource preact */\nexport const App = () => <p>hi</p>;\n',
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');

    const r = await runZntcInDir(fx.dir, [
      '--bundle',
      'app.tsx',
      '-o',
      out,
      '--platform=browser',
      '--format=esm',
      '--packages=external',
      '--jsx=automatic',
    ]);
    expect(r.exitCode).toBe(0);

    const code = await readFile(out, 'utf8');
    expect(code).toContain('"preact/jsx-runtime"');
  });
});
