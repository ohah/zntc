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
// scope (P2): 직접 named import(`import { foo } from './synth'`)만 지원. re-export forwarding
// (`export { foo } from './synth'`)·nested synthetic indirection 은 미지원(synthExportFallback 이
// resolveImports/seedExport 에만 배선) — Rollup 은 지원하나 수요 발생 시 follow-up.
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
