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

// #1880 PR4 — this.resolve(source, importer?, { skipSelf }). native resolver(순수 path
// resolution, graph 미접근) 를 JS context 에서 sync 호출 → Promise 로 감싼다. race/deadlock 없음.
describe('@zntc/core build + plugins - this.resolve', () => {
  test('this.resolve(상대경로) 가 resolved id 를 반환한다', async () => {
    let resolved: { id: string; external?: boolean } | null = null;
    const plugin: ZntcPlugin = {
      name: 'resolver-rel',
      setup(build) {
        build.onLoad(
          { filter: /main\.ts$/ },
          async function (this: RollupPluginContext, args: { path: string }) {
            resolved = await this.resolve('./dep.ts', args.path, { skipSelf: true });
            return null;
          },
        );
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-resolve-rel-'));
    try {
      writeFileSync(join(dir, 'dep.ts'), 'export const d = 1;\n');
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expect(resolved).not.toBeNull();
      expect(resolved!.id).toContain('dep.ts');
      expect(resolved!.external).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('this.resolve(존재하지 않는 모듈) 은 null', async () => {
    let resolved: unknown = 'unset';
    const plugin: ZntcPlugin = {
      name: 'resolver-null',
      setup(build) {
        build.onLoad(
          { filter: /main\.ts$/ },
          async function (this: RollupPluginContext, args: { path: string }) {
            resolved = await this.resolve('./does-not-exist-xyz.ts', args.path);
            return null;
          },
        );
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-resolve-null-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expect(resolved).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('this.resolve 는 resolveId hook 에서도 동작한다 (skipSelf 재귀 없음)', async () => {
    let resolved: { id: string } | null = null;
    let fired = false;
    const plugin: ZntcPlugin = {
      name: 'resolver-in-resolveid',
      setup(build) {
        // 실제 import 되는 './dep.ts' 를 가로채는 resolveId hook — 반드시 발화한다.
        build.onResolve(
          { filter: /dep\.ts$/ },
          async function (
            this: RollupPluginContext,
            args: { path: string; importer: string | null },
          ) {
            fired = true;
            // 자기 hook 안에서 this.resolve 호출 — native resolver 만 타므로 재귀 없음(skipSelf).
            resolved = await this.resolve(args.path, args.importer, { skipSelf: true });
            return null; // 실제 resolve 는 native 에 위임
          },
        );
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-resolve-rid-'));
    try {
      writeFileSync(join(dir, 'dep.ts'), 'export const d = 1;\n');
      writeFileSync(join(dir, 'main.ts'), "import './dep.ts';\nexport const x = 1;\n");
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expect(fired).toBe(true); // hook 이 실제로 발화했는지 보장 (vacuous 방지)
      expect(resolved).not.toBeNull();
      expect(resolved!.id).toContain('dep.ts');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('this.resolve(external 패턴) 은 { external: true } 를 반환한다', async () => {
    let resolved: { id: string; external?: boolean } | null = null;
    const plugin: ZntcPlugin = {
      name: 'resolver-external',
      setup(build) {
        build.onLoad(
          { filter: /main\.ts$/ },
          async function (this: RollupPluginContext, args: { path: string }) {
            resolved = await this.resolve('some-external-pkg', args.path);
            return null;
          },
        );
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-resolve-ext-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        external: ['some-external-pkg'],
      });
      expect(result.errors.length).toBe(0);
      expect(resolved).not.toBeNull();
      expect(resolved!.id).toBe('some-external-pkg');
      expect(resolved!.external).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
