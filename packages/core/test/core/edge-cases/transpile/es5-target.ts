import {
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../../helpers';

describe('@zntc/core edge cases: transpile ES5 target', () => {
  test('build target es5 keeps optional chaining temp declarations in nested functions', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es5-optional-temp-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          function createProxy(state: any) {
            state.callbacks.push(function rootDraftCleanup(rootScope: any) {
              rootScope.mapSetPlugin_?.fixSetContents(state);
              const { patchPlugin_ } = rootScope;
              if (state.modified_ && patchPlugin_) {
                patchPlugin_.generatePatches_(state, [], rootScope);
              }
            });
          }

          const calls: string[] = [];
          const state = { callbacks: [] as Function[], modified_: true };
          createProxy(state);
          state.callbacks[0]({
            mapSetPlugin_: { fixSetContents() { calls.push("map"); } },
            patchPlugin_: { generatePatches_() { calls.push("patch"); } },
          });
          globalThis.__VALUE__ = calls.join(",");
        `,
      );

      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        target: 'es5',
      });
      expect(result.errors.length).toBe(0);
      const code = result.outputFiles[0].text;
      expect(code).not.toContain('?.');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(code, sandbox);
      expect(sandbox.__VALUE__).toBe('map,patch');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
