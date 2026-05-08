import {
  afterAll,
  beforeAll,
  build,
  describe,
  expectPluginDiagnostic,
  join,
  mkdtempSync,
  resolve,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core build + plugins - plugin_error diagnostics', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-napi-plugin-diagnostic-'));
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('plugin_error: onLoad sync throw가 diagnostic으로 노출됨', async () => {
    const throwPlugin: ZntcPlugin = {
      name: 'throw-plugin',
      setup(build) {
        build.onResolve({ filter: /\.boom$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.boom$/ }, () => {
          throw new Error('plugin error!');
        });
      },
    };
    writeFileSync(join(dir, 'entry-load-error.ts'), 'import "./style.boom";');

    const result = await build({
      entryPoints: [join(dir, 'entry-load-error.ts')],
      plugins: [throwPlugin],
    });
    expectPluginDiagnostic(result, {
      plugin: 'throw-plugin',
      hook: 'load',
      message: 'plugin error!',
      fileIncludes: 'style.boom',
    });
  });

  test('plugin_error: onTransform async reject가 diagnostic으로 노출됨', async () => {
    const rejectPlugin: ZntcPlugin = {
      name: 'reject-transform',
      setup(build) {
        build.onTransform({ filter: /transform-reject\.ts$/ }, async () => {
          throw new Error('async transform rejected');
        });
      },
    };
    writeFileSync(join(dir, 'transform-reject.ts'), 'console.log("transform");');

    const result = await build({
      entryPoints: [join(dir, 'transform-reject.ts')],
      plugins: [rejectPlugin],
    });
    expectPluginDiagnostic(result, {
      plugin: 'reject-transform',
      hook: 'transform',
      message: 'async transform rejected',
      fileIncludes: 'transform-reject.ts',
    });
  });
});
