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

// #3664 P2: Rollup syntheticNamedExports. plugin 이 load 결과에 syntheticNamedExports 를 달면,
// 그 모듈에서 정적으로 export 안 된 named import 를 default(true) 또는 지정 export(string)의
// member 로 fallback 한다. ZTS 의 CJS interop fallback(resolveOrCjsFallback)과 같은 메커니즘이되
// 대상이 namespace 가 아니라 default/named export value.
// 직접 named import 와 barrel re-export forwarding(`export {foo} from './synth'`) 모두 지원.
// resolveExportChain 한 곳에서 synthetic 을 canonical.synthetic_member 로 해석하므로 codegen·
// tree_shaker 가 통합 경로로 따라온다.
describe('@zntc/core - syntheticNamedExports (#3664 P2)', () => {
  test('syntheticNamedExports:true → 정적 export 없는 named import 를 default export member 로 fallback', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-synth-true-'));
    const plugin: ZntcPlugin = {
      name: 'synth-true',
      setup(build) {
        build.onLoad({ filter: /synth\.ts$/ }, () => ({
          // default 만 export — foo/bar 는 정적으로 export 되지 않는다.
          contents: 'export default { foo: 42, bar: 7 };\n',
          syntheticNamedExports: true,
        }));
      },
    };
    try {
      writeFileSync(join(dir, 'synth.ts'), 'export default {};\n');
      writeFileSync(
        join(dir, 'main.ts'),
        "import { foo, bar } from './synth';\nexport const r = foo + bar;\n",
      );
      const result = await build({ entryPoints: [join(dir, 'main.ts')], plugins: [plugin] });
      // synthetic 없으면 foo/bar 가 missing_export 로 errors>0. synthetic 이면 default.foo 로 fallback.
      expect(result.errors.length).toBe(0);
      const out = result.outputFiles.map((f) => f.text).join('\n');
      // foo/bar 가 default export 객체의 member 접근으로 codegen 되어야 한다(.foo / .bar).
      expect(out).toContain('.foo');
      expect(out).toContain('.bar');
      // synthetic fallback 이 default export 를 참조 → synth 모듈(default 객체)이 tree-shaking 생존.
      expect(out).toContain('42');
      expect(out).toContain('7');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('re-export forwarding: export {foo} from synthetic → barrel 거쳐 import 도 default member', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-synth-reexport-'));
    const plugin: ZntcPlugin = {
      name: 'synth-reexport',
      setup(build) {
        build.onLoad({ filter: /synth\.ts$/ }, () => ({
          contents: 'export default { foo: 42, bar: 7 };\n',
          syntheticNamedExports: true,
        }));
      },
    };
    try {
      writeFileSync(join(dir, 'synth.ts'), 'export default {};\n');
      // barrel 이 synthetic 모듈의 이름을 forwarding.
      writeFileSync(join(dir, 're.ts'), "export { foo, bar } from './synth';\n");
      writeFileSync(
        join(dir, 'main.ts'),
        "import { foo, bar } from './re';\nexport const r = foo + bar;\n",
      );
      const result = await build({ entryPoints: [join(dir, 'main.ts')], plugins: [plugin] });
      expect(result.errors.length).toBe(0);
      const out = result.outputFiles.map((f) => f.text).join('\n');
      expect(out).toContain('.foo');
      expect(out).toContain('.bar');
      expect(out).toContain('42');
      expect(out).toContain('7');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('export * 는 synthetic 을 전파하지 않는다 — 임의 이름이 default member 로 새지 않음(회귀 가드)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-synth-star-'));
    const plugin: ZntcPlugin = {
      name: 'synth-star',
      setup(build) {
        build.onLoad({ filter: /synth\.ts$/ }, () => ({
          contents: 'export default { foo: 42 };\n',
          syntheticNamedExports: true,
        }));
      },
    };
    try {
      writeFileSync(join(dir, 'synth.ts'), 'export default {};\n');
      // star re-export 는 synthetic 이름을 forwarding 하지 않는다(Rollup: non-enumerable).
      writeFileSync(join(dir, 'star.ts'), "export * from './synth';\n");
      writeFileSync(
        join(dir, 'main.ts'),
        "import { neverExists } from './star';\nexport const r = neverExists;\n",
      );
      const result = await build({ entryPoints: [join(dir, 'main.ts')], plugins: [plugin] });
      const out = result.outputFiles.map((f) => f.text).join('\n');
      // neverExists 가 synth default 의 member(.neverExists)로 잘못 resolve 되면 안 된다.
      expect(out).not.toContain('.neverExists');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('synthetic 없는 모듈은 default-member fallback 을 하지 않는다(회귀 가드)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-synth-none-'));
    try {
      writeFileSync(join(dir, 'plain.ts'), 'export default {};\n');
      writeFileSync(
        join(dir, 'main.ts'),
        "import { ghost } from './plain';\nexport const r = ghost;\n",
      );
      const result = await build({ entryPoints: [join(dir, 'main.ts')] });
      // synthetic 아닌 모듈은 기존 동작 유지 — ghost 가 default member(.ghost)로 재작성되지 않는다.
      const out = result.outputFiles.map((f) => f.text).join('\n');
      expect(out).not.toContain('.ghost');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
