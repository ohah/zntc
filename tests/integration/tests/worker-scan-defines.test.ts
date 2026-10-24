import { afterAll, afterEach, beforeAll, describe, expect, test } from 'bun:test';
import { join } from 'node:path';
import { build, close, init } from '../../../packages/core/index';
import { createFixture } from './helpers';

describe('worker dependency scans inherit defines (#4603)', () => {
  beforeAll(() => init());
  afterAll(() => close());
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const cases: {
    name: string;
    directory: string;
    mode: string;
    define: Record<string, string>;
    enabled?: boolean;
  }[] = [
    { name: 'literal control', directory: '"./pages"', mode: '"sync"', define: {} },
    {
      name: 'enabled branch control',
      directory: '"./pages"',
      mode: '"sync"',
      define: { __ENABLED__: 'true' },
      enabled: true,
    },
    {
      name: 'identifier directory',
      directory: '__CONTEXT_ROOT__',
      mode: '"sync"',
      define: { __CONTEXT_ROOT__: '"./pages"' },
    },
    {
      name: 'member directory',
      directory: 'process.env.CONTEXT_ROOT',
      mode: '"sync"',
      define: { 'process.env.CONTEXT_ROOT': '"./pages"' },
    },
    {
      name: 'mode',
      directory: '"./pages"',
      mode: '__CONTEXT_MODE__',
      define: { __CONTEXT_MODE__: '"sync"' },
    },
    {
      name: 'directory and mode',
      directory: '__CONTEXT_ROOT__',
      mode: '__CONTEXT_MODE__',
      define: { __CONTEXT_ROOT__: '"./pages"', __CONTEXT_MODE__: '"sync"' },
    },
    {
      name: 'disabled branch control',
      directory: '__CONTEXT_ROOT__',
      mode: '"sync"',
      define: { __CONTEXT_ROOT__: '"./missing"', __ENABLED__: 'false' },
      enabled: false,
    },
  ];

  for (const moduleWorker of [false, true]) {
    for (const config of cases) {
      test(`${moduleWorker ? 'module' : 'classic'} worker: ${config.name}`, async () => {
        const context = `const ctx = require.context(${config.directory}, false, /\\.ts$/, ${config.mode}); console.log(JSON.stringify({ keys: ctx.keys().sort(), values: ctx.keys().sort().map(k => ctx(k).value) }));`;
        const created = await createFixture({
          'main.ts': `console.log(new Worker(new URL('./worker.ts', import.meta.url)${moduleWorker ? ", { type: 'module' }" : ''}));`,
          'worker.ts':
            config.enabled === undefined
              ? context
              : `if (__ENABLED__) { ${context} } else console.log('disabled');`,
          'pages/a.ts': 'export const value = "worker-context-a";',
          'pages/b.ts': 'export const value = "worker-context-b";',
        });
        cleanup = created.cleanup;
        const calls: { dir: string; recursive: boolean; filter?: string }[] = [];
        const result = await build({
          entryPoints: [join(created.dir, 'main.ts')],
          outdir: join(created.dir, 'dist'),
          define: config.define,
          plugins: [
            {
              name: 'worker-context-files',
              setup(plugin) {
                plugin.onResolveContext({ filter: /.*/ }, (args) => {
                  calls.push({ dir: args.dir, recursive: args.recursive, filter: args.filter });
                  return { context: ['./a.ts', './b.ts'] };
                });
              },
            },
          ],
        });
        expect(result.errors).toHaveLength(0);
        const workers = result.outputFiles.filter((f) =>
          /^worker-.*\.js$/.test(f.path.split('/').pop()!),
        );
        expect(workers).toHaveLength(1);
        const chunk = workers[0].text;
        const execution = Bun.spawnSync([process.execPath, '-e', chunk]);
        expect(execution.exitCode, execution.stderr.toString()).toBe(0);
        expect(execution.stdout.toString().trim()).toBe(
          config.enabled === false
            ? 'disabled'
            : JSON.stringify({
                keys: ['./a.ts', './b.ts'],
                values: ['worker-context-a', 'worker-context-b'],
              }),
        );
        expect(calls).toEqual(
          config.enabled === false ? [] : [{ dir: './pages', recursive: false, filter: '\\.ts$' }],
        );
      });
    }
  }
});
