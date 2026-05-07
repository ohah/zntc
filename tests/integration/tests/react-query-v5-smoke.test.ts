import { afterEach, describe, expect, it } from 'bun:test';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, hasPackage, linkNodeModules, runNode, runZntcInDir } from './helpers';

const hasReactQuery = hasPackage('@tanstack/react-query');

describe.skipIf(!hasReactQuery)('React Query v5 smoke', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  it('@tanstack/react-query v5 bundles to ES5 and runs replaceAll through runtime polyfills', async () => {
    const fixture = await createFixture({
      'index.ts': `
        import { QueryClient, QueryObserver } from "@tanstack/react-query";

        type Result = { ok: true; value: number };
        const normalized = "react.query.v5".replaceAll(".", "-");
        const client = new QueryClient();
        const observer = new QueryObserver<Result>(client, {
          queryKey: ["runtime-polyfills", "react-query-v5"],
          queryFn: async () => ({ ok: true, value: 42 }),
        });

        const unsubscribe = observer.subscribe(() => {});

        client
          .fetchQuery({
            queryKey: ["runtime-polyfills", "react-query-v5"],
            queryFn: async () => ({ ok: true, value: 42 }),
          })
          .then((result) => {
            console.log(normalized, result?.ok === true, result.value);
            unsubscribe();
            client.clear();
          });
      `,
    });
    cleanup = fixture.cleanup;

    await linkNodeModules(fixture.dir, ['@tanstack/react-query', '@tanstack/query-core', 'react']);

    const outFile = join(fixture.dir, 'out.cjs');
    const bundle = await runZntcInDir(
      fixture.dir,
      [
        '--bundle',
        join(fixture.dir, 'index.ts'),
        '-o',
        outFile,
        '--format=cjs',
        '--platform=node',
        '--target=es5',
        '--runtime-polyfills=auto',
        '--runtime-target=ios_saf 12',
      ],
      { bin: 'js' },
    );
    expect(bundle.exitCode).toBe(0);

    const js = await readFile(outFile, 'utf-8');
    expect(js).toContain('QueryClient');
    expect(js).toContain('es.string.replace-all');
    expect(js).not.toContain('@tanstack/react-query');
    expect(js).not.toContain('?.');
    expect(js.replace(/^\/\/#.*$/gm, '')).not.toMatch(/(^|[^\w$])#[A-Za-z_$][\w$]*/);

    const runner = join(fixture.dir, 'run-without-native-replaceall.cjs');
    await writeFile(
      runner,
      `String.prototype.replaceAll = undefined;\nrequire(${JSON.stringify(outFile)});\n`,
    );
    const run = await runNode(runner);
    expect(run.stdout).toBe('react-query-v5 true 42');
  });
});
