import {
  describe,
  test,
  expect,
  transpile,
  build,
  buildSync,
  resolve,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('@zntc/core 옵션 조합 심화', () => {
  test('hashbang + minify', () => {
    const result = transpile(
      '#!/usr/bin/env node\nconst longVariableName = 42;\nconsole.log(longVariableName);',
      {
        minify: true,
        target: 'es2023',
      },
    );
    expect(result.code).toContain('#!/usr/bin/env node');
    expect(result.code.length).toBeLessThan(80);
  });

  test('hashbang + sourcemap + es2022 (hashbang 제거됨)', () => {
    const result = transpile('#!/usr/bin/env node\nconst x = 1;', {
      sourcemap: true,
      target: 'es2022',
    });
    expect(result.code).not.toContain('#!');
    expect(result.map).toBeDefined();
  });

  test('buildSync + define + alias + sourcemap 동시', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-combo-all-'));
    writeFileSync(join(dir, 'real.ts'), 'export const val = 42;');
    writeFileSync(
      join(dir, 'index.ts'),
      'import { val } from "@mod";\nconsole.log(val, __VERSION__);',
    );

    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      define: { __VERSION__: '"1.0"' },
      alias: { '@mod': join(dir, 'real.ts') },
      sourcemap: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('42');
    expect(result.outputFiles[0].text).toContain('1.0');
    expect(result.outputFiles.length).toBe(2); // js + map
    rmSync(dir, { recursive: true, force: true });
  });

  test('transpile: 모든 ES 타겟 순회 (es5~esnext)', () => {
    const targets = [
      'es5',
      'es2015',
      'es2016',
      'es2017',
      'es2018',
      'es2019',
      'es2020',
      'es2021',
      'es2022',
      'es2023',
      'es2024',
      'es2025',
      'esnext',
    ] as const;
    for (const target of targets) {
      const result = transpile('const x = () => 1;', { target });
      expect(result.code.length).toBeGreaterThan(0);
      if (target === 'es5') {
        // es5에서만 arrow function 다운레벨
        expect(result.code).not.toContain('=>');
      } else {
        // es2015+에서는 arrow function 유지
        expect(result.code).toContain('=>');
      }
    }
  });

  test('build + platform=node + jsx=automatic + plugins (실제 코드 변환)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-combo-node-jsx-'));
    writeFileSync(join(dir, 'app.tsx'), 'export default () => <div>hello</div>;');

    const result = await build({
      entryPoints: [join(dir, 'app.tsx')],
      platform: 'node',
      jsx: 'automatic',
      external: ['react/jsx-runtime'],
      plugins: [
        {
          name: 'replace-transform',
          setup(build) {
            // 주석이 아닌 실제 코드 변환 (주석은 파서에서 제거됨)
            build.onTransform({ filter: /\.tsx$/ }, (args) => ({
              code: args.code.replace('hello', 'transformed'),
            }));
          },
        },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('transformed');
    expect(result.outputFiles[0].text).toContain('jsx-runtime');
    rmSync(dir, { recursive: true, force: true });
  });

  test('build + define + plugins (define은 NAPI, plugin은 JS)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-define-plugin-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import css from "./style.css";\nconsole.log(__MODE__, css);',
    );

    const cssPlugin: ZntcPlugin = {
      name: 'css',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.css$/ }, () => ({ contents: 'export default "red";' }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      define: { __MODE__: '"production"' },
      plugins: [cssPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('production');
    expect(result.outputFiles[0].text).toContain('red');
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── 새 BuildOptions 테스트 ───
