import {
  build,
  buildSync,
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

// #1880 PR1 — plugin hook 의 `this` context: this.warn / this.error.
describe('@zntc/core build + plugins - plugin context (this.warn / this.error)', () => {
  test('this.warn 은 result.warnings 로 surfacing (transform hook)', async () => {
    const warnPlugin: ZntcPlugin = {
      name: 'warner',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, function (this: RollupPluginContext, _args) {
          this.warn('heads up from transform');
          return null;
        });
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-ctx-warn-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'console.log(1);');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [warnPlugin],
      });
      expect(result.errors.length).toBe(0);
      // warn 메시지 + plugin 이름 prefix 가 result.warnings 에 들어와야 한다.
      expect(result.warnings.some((w) => w.text.includes('heads up from transform'))).toBe(true);
      expect(result.warnings.some((w) => w.text.includes('warner'))).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('this.error 는 plugin failure 로 result.errors 에 들어간다', async () => {
    const errPlugin: ZntcPlugin = {
      name: 'boomer',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, function (this: RollupPluginContext, _args) {
          this.error('explode from transform');
        });
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-ctx-err-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'console.log(1);');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [errPlugin],
      });
      expect(result.errors.some((e) => e.text.includes('explode from transform'))).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('buildSync 에서도 this.warn 이 surfacing 된다', () => {
    const warnPlugin: ZntcPlugin = {
      name: 'sync-warner',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, function (this: RollupPluginContext, _args) {
          this.warn('sync heads up');
          return null;
        });
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-ctx-sync-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'console.log(1);');
      const result = buildSync({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [warnPlugin],
      });
      expect(result.errors.length).toBe(0);
      expect(result.warnings.some((w) => w.text.includes('sync heads up'))).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('this 를 쓰지 않는 plugin 은 영향 없이 동작한다', async () => {
    const plainPlugin: ZntcPlugin = {
      name: 'plain',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (args) => ({
          code: args.code.replace('console.log', 'console.warn'),
        }));
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-ctx-plain-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'console.log("hello");');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plainPlugin],
      });
      expect(result.errors.length).toBe(0);
      expect(result.warnings.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('console.warn');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
