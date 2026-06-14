import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { init } from '../index.ts';
import {
  defineWorkspace,
  filterWorkspaces,
  findWorkspacePath,
  identifyWorkspaceEntries,
  loadIdentifiedConfig,
  loadWorkspace,
} from './workspace.ts';

beforeAll(() => init());

describe('defineWorkspace', () => {
  test('identity — 입력 그대로 반환', () => {
    const arr = ['./packages/a', { name: 'b' }] as const;
    expect(defineWorkspace(arr as never)).toBe(arr);
    const fn = () => [];
    expect(defineWorkspace(fn as never)).toBe(fn);
  });
});

describe('findWorkspacePath', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-workspace-find-'));
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('workspace 파일 없으면 null', () => {
    expect(findWorkspacePath(dir)).toBeNull();
  });

  test('.ts 우선순위', () => {
    const tsPath = join(dir, 'zntc.workspace.ts');
    const jsPath = join(dir, 'zntc.workspace.js');
    writeFileSync(tsPath, 'export default []');
    writeFileSync(jsPath, 'export default []');
    expect(findWorkspacePath(dir)).toBe(tsPath);
  });
});

describe('loadWorkspace', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-workspace-load-'));
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('.ts: 배열 export', async () => {
    const p = join(dir, 'a.workspace.ts');
    writeFileSync(p, `export default ["./pkg-a", { name: "shared" }]`);
    const ws = await loadWorkspace(p);
    expect(ws).toEqual(['./pkg-a', { name: 'shared' }]);
  });

  test('.json: 배열 export', async () => {
    const p = join(dir, 'b.workspace.json');
    writeFileSync(p, JSON.stringify(['./pkg-x', { name: 'y' }]));
    const ws = await loadWorkspace(p);
    expect(ws).toEqual(['./pkg-x', { name: 'y' }]);
  });

  test('함수형 — env 호출', async () => {
    const p = join(dir, 'fn.workspace.ts');
    writeFileSync(
      p,
      `export default ({ mode }: { mode: string }) => mode === "test" ? [{ name: "t" }] : [{ name: "p" }]`,
    );
    const ws = await loadWorkspace(p, { command: 'bundle', mode: 'test', env: {} });
    expect(ws).toEqual([{ name: 't' }]);
  });

  test('함수형 — env 미제공 시 default production', async () => {
    const p = join(dir, 'fn-default.workspace.ts');
    writeFileSync(p, `export default ({ mode }: { mode: string }) => [{ name: mode }]`);
    const ws = await loadWorkspace(p);
    expect(ws).toEqual([{ name: 'production' }]);
  });

  test('배열 아니면 throw', async () => {
    const p = join(dir, 'obj.workspace.ts');
    writeFileSync(p, `export default { name: "oops" }`);
    expect(loadWorkspace(p)).rejects.toThrow(/must export an array/);
  });

  test('inline entry 에 name 없으면 throw', async () => {
    const p = join(dir, 'noname.workspace.ts');
    writeFileSync(p, `export default [{ entryPoints: ["x.ts"] }]`);
    expect(loadWorkspace(p)).rejects.toThrow(/non-empty 'name'/);
  });

  test('entry 가 number 면 throw', async () => {
    const p = join(dir, 'badtype.workspace.ts');
    writeFileSync(p, `export default [42]`);
    expect(loadWorkspace(p)).rejects.toThrow(/must be a string or object/);
  });

  test('string entry 가 빈 문자열이면 throw', async () => {
    const p = join(dir, 'empty.workspace.ts');
    writeFileSync(p, `export default [""]`);
    expect(loadWorkspace(p)).rejects.toThrow(/empty string/);
  });
});

describe('identifyWorkspaceEntries', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-workspace-identify-'));
    // Layout:
    //   <dir>/packages/app          — package.json name="my-app" + zntc.config.json
    //   <dir>/packages/lib-a        — package.json name="@scope/a"
    //   <dir>/packages/lib-b        — (no package.json — fallback to dirname)
    //   <dir>/packages/.hidden      — should NOT match * glob
    //   <dir>/packages/node_modules — should NOT match * glob
    const pkgs = join(dir, 'packages');
    mkdirSync(pkgs, { recursive: true });

    const app = join(pkgs, 'app');
    mkdirSync(app);
    writeFileSync(join(app, 'package.json'), JSON.stringify({ name: 'my-app' }));
    writeFileSync(
      join(app, 'zntc.config.json'),
      JSON.stringify({ format: 'esm', entryPoints: ['./entry.ts'] }),
    );

    const libA = join(pkgs, 'lib-a');
    mkdirSync(libA);
    writeFileSync(join(libA, 'package.json'), JSON.stringify({ name: '@scope/a' }));

    const libB = join(pkgs, 'lib-b');
    mkdirSync(libB);
    // no package.json

    mkdirSync(join(pkgs, '.hidden'));
    mkdirSync(join(pkgs, 'node_modules'));
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('inlineConfig 분리 — inline entry 만 채워짐', () => {
    const r = identifyWorkspaceEntries(
      ['./packages/app', { name: 'shared', entryPoints: ['./shared/x.ts'] }],
      dir,
    );
    expect(r).toHaveLength(2);
    expect(r[0]?.inlineConfig).toBeNull(); // path 는 후처리 필요
    expect(r[1]?.inlineConfig).toEqual({ entryPoints: ['./shared/x.ts'] });
    expect((r[1]?.inlineConfig as { name?: string } | null)?.name).toBeUndefined();
  });

  test('string path — package.json name 사용 (config 로드 없음)', () => {
    const r = identifyWorkspaceEntries(['./packages/app'], dir);
    expect(r).toHaveLength(1);
    expect(r[0]?.name).toBe('my-app');
    expect(r[0]?.cwd).toBe(join(dir, 'packages', 'app'));
    expect(r[0]?.source).toBe('path');
    expect(r[0]?.inlineConfig).toBeNull();
  });

  test('string path — scoped package.json name 사용', () => {
    const r = identifyWorkspaceEntries(['./packages/lib-a'], dir);
    expect(r[0]?.name).toBe('@scope/a');
  });

  test('string path — package.json 없으면 디렉토리명 fallback', () => {
    const r = identifyWorkspaceEntries(['./packages/lib-b'], dir);
    expect(r[0]?.name).toBe('lib-b');
  });

  test('glob `./packages/*` — 매칭 디렉토리 모두, hidden/node_modules 제외', () => {
    const r = identifyWorkspaceEntries(['./packages/*'], dir);
    const names = r.map((e) => e.name).sort();
    expect(names).toEqual(['@scope/a', 'lib-b', 'my-app']);
    expect(r.every((e) => e.source === 'glob')).toBe(true);
  });

  test('glob `./packages/lib-*` — prefix 매칭', () => {
    const r = identifyWorkspaceEntries(['./packages/lib-*'], dir);
    const names = r.map((e) => e.name).sort();
    expect(names).toEqual(['@scope/a', 'lib-b']);
  });

  test('inline object — name 추출 + cwd = rootDir + source=inline', () => {
    const r = identifyWorkspaceEntries([{ name: 'shared', entryPoints: ['./shared.ts'] }], dir);
    expect(r).toHaveLength(1);
    expect(r[0]?.name).toBe('shared');
    expect(r[0]?.cwd).toBe(dir);
    expect(r[0]?.source).toBe('inline');
  });

  test('다중 inline 엔트리 — 모두 식별 (cwd 동일이어도 name 으로 dedup) (#4285)', () => {
    const r = identifyWorkspaceEntries(
      [
        { name: 'a', entryPoints: ['./a.ts'] },
        { name: 'b', entryPoints: ['./b.ts'] },
        { name: 'c', entryPoints: ['./c.ts'] },
      ],
      dir,
    );
    // 버그 땐 cwd(=rootDir) dedup 으로 'a' 만 남았다.
    expect(r.map((e) => e.name)).toEqual(['a', 'b', 'c']);
    // name 필터가 두 번째 이후 inline 도 찾을 수 있어야 한다.
    expect(filterWorkspaces(r, 'b').map((e) => e.name)).toEqual(['b']);
  });

  test('다중 inline — 같은 name 은 첫 번째만 (dedup)', () => {
    const r = identifyWorkspaceEntries(
      [
        { name: 'dup', entryPoints: ['./1.ts'] },
        { name: 'dup', entryPoints: ['./2.ts'] },
      ],
      dir,
    );
    expect(r).toHaveLength(1);
  });

  test('3종 형식 동시 사용', () => {
    const r = identifyWorkspaceEntries(
      ['./packages/app', './packages/lib-*', { name: 'inline-x', entryPoints: ['x'] }],
      dir,
    );
    const names = r.map((e) => e.name).sort();
    expect(names).toEqual(['@scope/a', 'inline-x', 'lib-b', 'my-app']);
  });

  test('glob `**` 미지원 — throw', () => {
    expect(() => identifyWorkspaceEntries(['./packages/**'], dir)).toThrow(/'\*\*'/);
  });

  test('glob 디렉토리부 `*` 미지원 — throw', () => {
    expect(() => identifyWorkspaceEntries(['./*/foo'], dir)).toThrow(/'\*' in directory/);
  });

  test('존재하지 않는 디렉토리 glob — 빈 결과', () => {
    const r = identifyWorkspaceEntries(['./nonexistent/*'], dir);
    expect(r).toEqual([]);
  });

  test('dedup: 같은 cwd 가 path + glob 양쪽에 매칭되면 첫 번째만 (path) 유지', () => {
    const r = identifyWorkspaceEntries(['./packages/app', './packages/*'], dir);
    const apps = r.filter((e) => e.name === 'my-app');
    expect(apps).toHaveLength(1);
    expect(apps[0]?.source).toBe('path');
  });

  test('dedup: 동일 path 중복 선언', () => {
    const r = identifyWorkspaceEntries(['./packages/app', './packages/app'], dir);
    const apps = r.filter((e) => e.cwd === join(dir, 'packages', 'app'));
    expect(apps).toHaveLength(1);
  });

  test('identify 후 loadIdentifiedConfig 로 zntc.config 자동 탐색 + 로드', async () => {
    const ids = identifyWorkspaceEntries(['./packages/app'], dir);
    const config = await loadIdentifiedConfig(ids[0]!);
    expect(config.format).toBe('esm');
    expect(config.entryPoints).toEqual(['./entry.ts']);
  });

  test('identify 후 loadIdentifiedConfig — config 없는 디렉토리는 빈 객체', async () => {
    const ids = identifyWorkspaceEntries(['./packages/lib-a'], dir);
    const config = await loadIdentifiedConfig(ids[0]!);
    expect(config).toEqual({});
  });
});

describe('loadIdentifiedConfig', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-workspace-loadid-'));
    const app = join(dir, 'app');
    mkdirSync(app);
    writeFileSync(
      join(app, 'zntc.config.json'),
      JSON.stringify({ format: 'esm', entryPoints: ['./entry.ts'] }),
    );
    const empty = join(dir, 'empty');
    mkdirSync(empty);
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('inline 인 경우 inlineConfig 그대로 반환 (디스크 read 없음)', async () => {
    const cfg = await loadIdentifiedConfig({
      name: 'x',
      cwd: '/nonexistent',
      source: 'inline',
      inlineConfig: { format: 'cjs' },
    });
    expect(cfg).toEqual({ format: 'cjs' });
  });

  test('path 면 cwd 의 zntc.config.* 로드', async () => {
    const cfg = await loadIdentifiedConfig({
      name: 'app',
      cwd: join(dir, 'app'),
      source: 'path',
      inlineConfig: null,
    });
    expect(cfg.format).toBe('esm');
    expect(cfg.entryPoints).toEqual(['./entry.ts']);
  });

  test('config 파일 없는 디렉토리 — 빈 객체', async () => {
    const cfg = await loadIdentifiedConfig({
      name: 'empty',
      cwd: join(dir, 'empty'),
      source: 'path',
      inlineConfig: null,
    });
    expect(cfg).toEqual({});
  });
});

describe('filterWorkspaces', () => {
  const ws = [
    { name: 'app', cwd: '/x/app', config: {}, source: 'path' as const },
    { name: 'lib', cwd: '/x/lib', config: {}, source: 'glob' as const },
  ];

  test('filter 없으면 전체 반환', () => {
    expect(filterWorkspaces(ws, undefined)).toBe(ws);
  });

  test('name 매칭', () => {
    const r = filterWorkspaces(ws, 'app');
    expect(r).toHaveLength(1);
    expect(r[0]?.name).toBe('app');
  });

  test('매칭 0개면 throw + available 목록 노출', () => {
    expect(() => filterWorkspaces(ws, 'ghost')).toThrow(/matched 0 entries.*available: app, lib/);
  });

  test('빈 워크스페이스에서 ghost 필터 — throw', () => {
    expect(() => filterWorkspaces([], 'anything')).toThrow(/<none>/);
  });
});
