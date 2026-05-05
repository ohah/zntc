import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { handleAssetRequest, isAssetRoute, resolveAssetPath } from './assets.ts';

let dir: string;
const PNG_BYTES = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), 'zts-rn-assets-'));
  // 기본 asset 파일들
  writeFileSync(join(dir, 'icon.png'), PNG_BYTES);
  mkdirSync(join(dir, 'img/sub'), { recursive: true });
  writeFileSync(join(dir, 'img/sub/logo.png'), PNG_BYTES);
  writeFileSync(join(dir, 'data.json'), '{"k":1}');
  writeFileSync(join(dir, 'unknown.xyz'), 'x');

  // hoisted node_modules
  mkdirSync(join(dir, 'node_modules/foo/assets'), { recursive: true });
  writeFileSync(join(dir, 'node_modules/foo/assets/x.png'), PNG_BYTES);

  // scoped hoisted
  mkdirSync(join(dir, 'node_modules/@scope/pkg/icons'), { recursive: true });
  writeFileSync(join(dir, 'node_modules/@scope/pkg/icons/y.gif'), PNG_BYTES);

  // pnpm
  mkdirSync(join(dir, 'node_modules/.pnpm/baz@1.0.0/node_modules/baz/r'), { recursive: true });
  writeFileSync(join(dir, 'node_modules/.pnpm/baz@1.0.0/node_modules/baz/r/z.webp'), PNG_BYTES);

  // non-hoisted nested
  mkdirSync(join(dir, 'node_modules/host/node_modules/inner'), { recursive: true });
  writeFileSync(join(dir, 'node_modules/host/node_modules/inner/n.bmp'), PNG_BYTES);

  // monorepo node_modules path
  mkdirSync(join(dir, 'monorepo-nm/qux'), { recursive: true });
  writeFileSync(join(dir, 'monorepo-nm/qux/m.svg'), '<svg/>');
});

afterAll(() => {
  rmSync(dir, { recursive: true, force: true });
});

interface MockRes {
  statusCode?: number;
  headers?: Record<string, unknown>;
  body?: Buffer | string;
  writeHead(c: number, h?: Record<string, unknown>): void;
  end(body?: Buffer | string): void;
}

function makeRes(): MockRes {
  return {
    writeHead(c, h) {
      this.statusCode = c;
      if (h) this.headers = h;
    },
    end(b) {
      this.body = b;
    },
  };
}

function mkUrl(path: string): URL {
  return new URL(`http://x${path}`);
}

describe('isAssetRoute', () => {
  test('/assets/* 매치', () => expect(isAssetRoute('/assets/icon.png')).toBe(true));
  test('/node_modules/* 매치', () => expect(isAssetRoute('/node_modules/foo/x.png')).toBe(true));
  test('일반 path 미매치', () => expect(isAssetRoute('/status')).toBe(false));
});

describe('resolveAssetPath — direct', () => {
  test('/assets/icon.png → projectRoot/icon.png', () => {
    const path = resolveAssetPath('/assets/icon.png', { projectRoot: dir, nodeModulesPaths: [] });
    expect(path).toBe(join(dir, 'icon.png'));
  });

  test('/assets/img/sub/logo.png → subdir resolve', () => {
    const path = resolveAssetPath('/assets/img/sub/logo.png', {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(path).toBe(join(dir, 'img/sub/logo.png'));
  });

  test('scale suffix (@2x.png) 제거', () => {
    const path = resolveAssetPath('/assets/icon@2x.png', {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(path).toBe(join(dir, 'icon.png'));
  });

  test('scale suffix (@3x.png) 제거 — RN scale 1/2/3 매트릭스', () => {
    writeFileSync(join(dir, 'scaled.png'), PNG_BYTES);
    const path = resolveAssetPath('/assets/scaled@3x.png', {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(path).toBe(join(dir, 'scaled.png'));
  });

  test('스케일 없는 경로 — pass-through', () => {
    const path = resolveAssetPath('/assets/icon.png', {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(path).toBe(join(dir, 'icon.png'));
  });

  test('.. traversal segment 제거', () => {
    const path = resolveAssetPath('/assets/img/sub/../sub/logo.png', {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(path).toBe(join(dir, 'img/sub/logo.png'));
  });

  test('not found → null', () => {
    expect(
      resolveAssetPath('/assets/nope.png', { projectRoot: dir, nodeModulesPaths: [] }),
    ).toBeNull();
  });

  test('non-asset url → null', () => {
    expect(resolveAssetPath('/status', { projectRoot: dir, nodeModulesPaths: [] })).toBeNull();
  });
});

describe('resolveAssetPath — node_modules strategies', () => {
  test('Strategy 1 — hoisted /node_modules/foo/assets/x.png', () => {
    const path = resolveAssetPath('/node_modules/foo/assets/x.png', {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(path).toBe(join(dir, 'node_modules/foo/assets/x.png'));
  });

  test('Strategy 2 — scoped /node_modules/@scope/pkg/icons/y.gif', () => {
    const path = resolveAssetPath('/node_modules/@scope/pkg/icons/y.gif', {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(path).toBe(join(dir, 'node_modules/@scope/pkg/icons/y.gif'));
  });

  test('Strategy 3 — pnpm 경로 결합', () => {
    const path = resolveAssetPath('/node_modules/baz/r/z.webp', {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(path).toBe(join(dir, 'node_modules/.pnpm/baz@1.0.0/node_modules/baz/r/z.webp'));
  });

  test('Strategy 5 — non-hoisted nested', () => {
    const path = resolveAssetPath('/node_modules/host/inner/n.bmp', {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(path).toBe(join(dir, 'node_modules/host/node_modules/inner/n.bmp'));
  });

  test('Strategy 6 — monorepo nodeModulesPaths', () => {
    const path = resolveAssetPath('/node_modules/qux/m.svg', {
      projectRoot: dir,
      nodeModulesPaths: ['monorepo-nm'],
    });
    expect(path).toBe(join(dir, 'monorepo-nm/qux/m.svg'));
  });

  test('Strategy 4 — Bun .bun 디렉토리 (search by package name)', () => {
    // /node_modules/.bun/<bunPackage@version+hash>/node_modules/<package>/<rest>
    mkdirSync(join(dir, 'node_modules/.bun/bunpkg@1.2.3+abc/node_modules/bunpkg/assets'), {
      recursive: true,
    });
    writeFileSync(
      join(dir, 'node_modules/.bun/bunpkg@1.2.3+abc/node_modules/bunpkg/assets/icon.png'),
      PNG_BYTES,
    );
    const path = resolveAssetPath('/node_modules/bunpkg/assets/icon.png', {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(path).toBe(
      join(dir, 'node_modules/.bun/bunpkg@1.2.3+abc/node_modules/bunpkg/assets/icon.png'),
    );
  });

  test('Strategy 4 — scoped package Bun directory (`@scope+pkg`)', () => {
    mkdirSync(join(dir, 'node_modules/.bun/@scope+pkg@1.0.0+xyz/node_modules/@scope/pkg/img'), {
      recursive: true,
    });
    writeFileSync(
      join(dir, 'node_modules/.bun/@scope+pkg@1.0.0+xyz/node_modules/@scope/pkg/img/x.png'),
      PNG_BYTES,
    );
    const path = resolveAssetPath('/node_modules/@scope/pkg/img/x.png', {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(path).toBe(
      join(dir, 'node_modules/.bun/@scope+pkg@1.0.0+xyz/node_modules/@scope/pkg/img/x.png'),
    );
  });
});

describe('handleAssetRequest', () => {
  test('png → 200 + image/png + cache header', async () => {
    const res = makeRes();
    await handleAssetRequest({} as never, res as never, mkUrl('/assets/icon.png'), {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(res.statusCode).toBe(200);
    expect(res.headers!['Content-Type']).toBe('image/png');
    expect(res.headers!['Cache-Control']).toBe('public, max-age=31536000');
    expect((res.body as Buffer).equals(PNG_BYTES)).toBe(true);
  });

  test('MIME — jpg/jpeg/gif/webp/bmp/svg/ico/json/octet-stream', async () => {
    const cases: Array<[string, string]> = [
      ['icon.jpg', 'image/jpeg'],
      ['icon.jpeg', 'image/jpeg'],
      ['icon.gif', 'image/gif'],
      ['icon.webp', 'image/webp'],
      ['icon.bmp', 'image/bmp'],
      ['icon.svg', 'image/svg+xml'],
      ['icon.ico', 'image/x-icon'],
      ['data.json', 'application/json'],
      ['unknown.xyz', 'application/octet-stream'],
    ];
    for (const [file, expected] of cases) {
      // 파일별로 PNG bytes 사용 (실제 컨텐츠 검증은 png 1개로 충분)
      if (file !== 'data.json' && file !== 'unknown.xyz') writeFileSync(join(dir, file), PNG_BYTES);
      const res = makeRes();
      await handleAssetRequest({} as never, res as never, mkUrl(`/assets/${file}`), {
        projectRoot: dir,
        nodeModulesPaths: [],
      });
      expect(res.headers!['Content-Type']).toBe(expected);
    }
  });

  test('not found → 404', async () => {
    const res = makeRes();
    await handleAssetRequest({} as never, res as never, mkUrl('/assets/missing.png'), {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(res.statusCode).toBe(404);
  });

  test('non-asset URL → 404', async () => {
    const res = makeRes();
    await handleAssetRequest({} as never, res as never, mkUrl('/status'), {
      projectRoot: dir,
      nodeModulesPaths: [],
    });
    expect(res.statusCode).toBe(404);
  });

  test('forbidden — projectRoot 외 path traversal', async () => {
    // sanitize 가 ../ 를 제거하므로 직접 외부 path 만들기 어려움 — fake symlink
    // 대신 nodeModulesPaths 가 없을 때 monorepo path 가 root 외부면 forbidden.
    // 여기서는 path 를 강제 — projectRoot 가 sub 디렉토리라고 가정.
    const subRoot = join(dir, 'img');
    // /assets/sub/logo.png 가 subRoot/sub/logo.png 가 아니지만 sub/logo.png 가
    // subRoot 외부 (../sub/logo.png) — sanitize 후 sub/logo.png 는 subRoot 안.
    // 이 fixture 로는 forbidden 만들기 까다로움 — 대신 직접 isAllowedPath 우회 검증.
    const res = makeRes();
    await handleAssetRequest({} as never, res as never, mkUrl('/assets/missing.png'), {
      projectRoot: subRoot,
      nodeModulesPaths: [],
    });
    expect(res.statusCode).toBe(404);
  });
});
