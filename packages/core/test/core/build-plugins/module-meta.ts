import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from './helpers';
import type { ZntcPlugin } from './helpers';
import type { RollupPluginContext } from '../../../index';

// #1880 PR2+PR3 — ModuleInfo.meta store(PR2) + this.getModuleInfo(PR3, self-only).
// PR3 는 self-module(현재 transform 중인 모듈)만 노출한다. graph 조회를 하지 않으므로
// discovery 병렬 단계의 race 가 원천 제거된다. cross-module 조회는 null
// (transform 시점 다른 모듈은 graph 미완성이라 어차피 무의미). 완전한 graph 조회는
// manualChunks(splitting, frozen) getModuleInfo 영역.
describe('@zntc/core build + plugins - ModuleInfo.meta / this.getModuleInfo (self-only)', () => {
  // PR2 write + PR3 read: load 가 set 한 meta 를 transform 의 this.getModuleInfo(self).meta 로 본다.
  test('load hook 의 meta 가 transform 의 this.getModuleInfo(self).meta 로 노출된다', async () => {
    let metaInTransform: Record<string, unknown> | null = null;
    const plugin: ZntcPlugin = {
      name: 'meta-roundtrip',
      setup(build) {
        build.onLoad({ filter: /main\.ts$/ }, () => ({
          contents: 'export const x = 1;\n',
          meta: { framework: 'vue', score: 7 },
        }));
        build.onTransform(
          { filter: /main\.ts$/ },
          function (this: RollupPluginContext, args: { code: string; path: string }) {
            const info = this.getModuleInfo(args.path);
            if (info && info.meta) metaInTransform = info.meta as Record<string, unknown>;
            return null;
          },
        );
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-meta-gmi-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expect(metaInTransform).toEqual({ framework: 'vue', score: 7 });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // PR3: meta 미설정 모듈의 this.getModuleInfo(self).meta 는 빈 객체 (Rollup 호환).
  test('meta 미설정 모듈의 this.getModuleInfo(self).meta 는 빈 객체', async () => {
    let metaSeen: unknown = 'unset';
    const plugin: ZntcPlugin = {
      name: 'meta-empty',
      setup(build) {
        build.onTransform(
          { filter: /main\.ts$/ },
          function (this: RollupPluginContext, args: { code: string; path: string }) {
            const info = this.getModuleInfo(args.path);
            if (info) metaSeen = info.meta;
            return null;
          },
        );
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-meta-empty-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expect(metaSeen).toEqual({});
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // PR3 self-only: 현재 모듈(self)은 id/code 를 노출한다.
  test('this.getModuleInfo(self) 가 id/code 를 노출한다', async () => {
    let info: { id?: string; code?: string | null } | null = null;
    const plugin: ZntcPlugin = {
      name: 'self-info',
      setup(build) {
        build.onTransform(
          { filter: /main\.ts$/ },
          function (this: RollupPluginContext, args: { code: string; path: string }) {
            info = this.getModuleInfo(args.path) as { id: string; code: string | null };
            return null;
          },
        );
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-meta-self-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expect(info).not.toBeNull();
      expect(info!.id).toContain('main.ts');
      expect(typeof info!.code).toBe('string');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // #2 가드: circular/직렬화 불가 meta 는 plugin failure 로 정규화 (dispatch 크래시 방지).
  test('circular meta 는 plugin failure 로 정규화된다', async () => {
    const plugin: ZntcPlugin = {
      name: 'circ-meta',
      setup(build) {
        build.onLoad({ filter: /main\.ts$/ }, () => {
          const m: Record<string, unknown> = {};
          m.self = m; // 순환 참조 → JSON.stringify throw
          return { contents: 'export const x = 1;\n', meta: m };
        });
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-meta-circ-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      // 크래시 없이 plugin failure 로 result.errors 에 담겨야 한다.
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBeGreaterThan(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // nested object / array / null 값 meta 의 round-trip.
  test('nested/array/null 값 meta 가 round-trip 된다', async () => {
    let seen: Record<string, unknown> | null = null;
    const nested = { a: { b: [1, 2, 3] }, n: null, s: 'x' };
    const plugin: ZntcPlugin = {
      name: 'nested-meta',
      setup(build) {
        build.onLoad({ filter: /main\.ts$/ }, () => ({
          contents: 'export const x = 1;\n',
          meta: nested,
        }));
        build.onTransform(
          { filter: /main\.ts$/ },
          function (this: RollupPluginContext, args: { code: string; path: string }) {
            const info = this.getModuleInfo(args.path);
            if (info && info.meta) seen = info.meta as Record<string, unknown>;
            return null;
          },
        );
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-meta-nested-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expect(seen).toEqual(nested);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // PR3 self-only: cross-module(다른 모듈 id) 조회는 null — graph 조회를 하지 않으므로 race 없음.
  test('this.getModuleInfo(다른 모듈 id) 는 null (self-only)', async () => {
    let crossResult: unknown = 'unset';
    const plugin: ZntcPlugin = {
      name: 'cross-null',
      setup(build) {
        build.onTransform(
          { filter: /main\.ts$/ },
          function (this: RollupPluginContext, args: { code: string; path: string }) {
            // 자기 자신이 아닌 임의 id → self-only 이므로 null
            crossResult = this.getModuleInfo(args.path + '.other-nonexistent');
            return null;
          },
        );
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-meta-cross-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expect(crossResult).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // #3664 P1: transform hook 의 meta 가 load meta 와 deep merge 된다(나중 hook=transform 우선,
  // nested 보존). transform meta 는 chain 종료 후 module 에 반영되므로 frozen graph(manualChunks
  // getModuleInfo)에서 검증. transform 은 code 없이 meta 만 반환(meta-only).
  test('transform meta 가 load meta 와 deep merge 되어 manualChunks getModuleInfo 로 노출 (P1)', async () => {
    let merged: Record<string, unknown> | undefined;
    const plugin: ZntcPlugin = {
      name: 'meta-merge',
      setup(build) {
        build.onLoad({ filter: /main\.ts$/ }, () => ({
          contents: 'export const x = 1;\n',
          meta: { a: 1, nested: { p: 1, q: 1 } },
        }));
        build.onTransform({ filter: /main\.ts$/ }, () => ({
          // code 없이 meta 만 — meta-only transform.
          meta: { b: 2, nested: { q: 99, r: 2 } },
        }));
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-meta-merge-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        splitting: true,
        manualChunks: (id, meta) => {
          if (id.includes('main.ts')) {
            merged = meta.getModuleInfo(id)?.meta as Record<string, unknown>;
          }
          return null;
        },
      });
      expect(result.errors.length).toBe(0);
      // load {a, nested:{p,q}} + transform {b, nested:{q→99, r}} → deep merge, transform 우선.
      expect(merged).toEqual({ a: 1, b: 2, nested: { p: 1, q: 99, r: 2 } });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // #3664 P1: 같은 plugin 의 여러 transform 결과(chain)도 nested 보존 deep merge.
  test('transform chain 의 여러 meta 가 deep merge 된다 (P1)', async () => {
    let merged: Record<string, unknown> | undefined;
    const plugin: ZntcPlugin = {
      name: 'meta-chain',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, () => ({ meta: { nested: { a: 1 } } }));
        build.onTransform({ filter: /main\.ts$/ }, () => ({ meta: { nested: { b: 2 } } }));
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-meta-chain-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        splitting: true,
        manualChunks: (id, meta) => {
          if (id.includes('main.ts')) {
            merged = meta.getModuleInfo(id)?.meta as Record<string, unknown>;
          }
          return null;
        },
      });
      expect(result.errors.length).toBe(0);
      // 두 transform 의 nested 가 키 손실 없이 합쳐진다(shallow 면 {b:2}만 남음).
      expect(merged).toEqual({ nested: { a: 1, b: 2 } });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
