import { afterEach, describe, expect, test } from 'bun:test';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, hasPackage, linkNodeModules, runNode, runZntcInDir } from './helpers';

const OLD_RUNTIME_ARGS = [
  '--format=cjs',
  '--platform=node',
  '--target=es5',
  '--runtime-polyfills=auto',
  '--runtime-target=safari 5',
];

function expectNoRawDownlevelSyntax(js: string) {
  expect(js).not.toContain('?.');
  expect(js.replace(/^\/\/#.*$/gm, '')).not.toMatch(/(^|[^\w$])#[A-Za-z_$][\w$]*/);
}

describe('runtime polyfills library smoke', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test.skipIf(!hasPackage('immer'))(
    'immer bundles to ES5 and runs Map/Set/Array.at through graph runtime polyfills',
    async () => {
      const fixture = await createFixture({
        'index.ts': `
          import { enableMapSet, produce } from "immer";

          enableMapSet();
          const base = {
            users: new Map([["ada", { count: 1 }]]),
            tags: new Set(["draft"]),
          };
          const next = produce(base, (draft) => {
            draft.users.get("ada").count += 1;
            draft.tags.add("published");
          });
          const last = Array.from(next.tags).at(-1);
          console.log("immer", next.users.get("ada")?.count, last);
        `,
      });
      cleanup = fixture.cleanup;
      await linkNodeModules(fixture.dir, ['immer']);

      const outFile = join(fixture.dir, 'out.cjs');
      const bundle = await runZntcInDir(
        fixture.dir,
        ['--bundle', join(fixture.dir, 'index.ts'), '-o', outFile, ...OLD_RUNTIME_ARGS],
        { bin: 'js' },
      );
      expect(bundle.exitCode).toBe(0);

      const js = await readFile(outFile, 'utf-8');
      expect(js).toContain('es.map');
      expect(js).toContain('es.set');
      expect(js).toContain('es.array.at');
      expectNoRawDownlevelSyntax(js);

      const runner = join(fixture.dir, 'run-without-native-collections.cjs');
      await writeFile(
        runner,
        `
          globalThis.Map = undefined;
          globalThis.Set = undefined;
          Array.prototype.at = undefined;
          require(${JSON.stringify(outFile)});
        `,
      );
      const run = await runNode(runner);
      expect(run.stdout).toBe('immer 2 published');
    },
  );

  test.skipIf(!hasPackage('rxjs'))(
    'rxjs bundles to ES5 and runs Promise/Map/Set/replaceAll through graph runtime polyfills',
    async () => {
      const fixture = await createFixture({
        'index.ts': `
          import { firstValueFrom, of } from "rxjs";
          import { distinct, groupBy, map, mergeMap, reduce } from "rxjs/operators";

          firstValueFrom(
            of("a", "b", "a").pipe(
              distinct(),
              groupBy((value) => value.length),
              mergeMap((group$) => group$.pipe(reduce((acc, value) => acc + value, ""))),
              map((value) => value.replaceAll("a", "A")),
            ),
          ).then((value) => console.log("rxjs", value));
        `,
      });
      cleanup = fixture.cleanup;
      await linkNodeModules(fixture.dir, ['rxjs']);

      const outFile = join(fixture.dir, 'out.cjs');
      const bundle = await runZntcInDir(
        fixture.dir,
        ['--bundle', join(fixture.dir, 'index.ts'), '-o', outFile, ...OLD_RUNTIME_ARGS],
        { bin: 'js' },
      );
      expect(bundle.exitCode).toBe(0);

      const js = await readFile(outFile, 'utf-8');
      expect(js).toContain('es.map');
      expect(js).toContain('es.set');
      expect(js).toContain('es.promise');
      expect(js).toContain('es.string.replace-all');
      expectNoRawDownlevelSyntax(js);

      const runner = join(fixture.dir, 'run-without-native-runtime.cjs');
      await writeFile(
        runner,
        `
          globalThis.Map = undefined;
          globalThis.Set = undefined;
          globalThis.Promise = undefined;
          String.prototype.replaceAll = undefined;
          require(${JSON.stringify(outFile)});
        `,
      );
      const run = await runNode(runner);
      expect(run.stdout).toBe('rxjs Ab');
    },
  );

  test('multi-module bundle runs runtime prelude before dependency top-level code', async () => {
    const fixture = await createFixture({
      'entry.ts': `
        import { value } from "./dep-c";
        console.log("multi-top-level", value);
      `,
      'dep-a.ts': `
        export const a = Object.values({ label: "value" })[0];
        export const b = Math.trunc(2.9);
      `,
      'dep-b.ts': `
        export const c = "7".padStart(2, "0");
        export const d = [1, 2, 3].findLast((value) => value < 3);
      `,
      'dep-c.ts': `
        import { a, b } from "./dep-a";
        import { c, d } from "./dep-b";
        const key = {};
        const weak = new WeakMap();
        weak.set(key, "weak");
        export const value = [a, b, c, d, weak.get(key)].join("|");
      `,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, 'out.cjs');
    const bundle = await runZntcInDir(
      fixture.dir,
      ['--bundle', join(fixture.dir, 'entry.ts'), '-o', outFile, ...OLD_RUNTIME_ARGS],
      { bin: 'js' },
    );
    expect(bundle.exitCode).toBe(0);

    const js = await readFile(outFile, 'utf-8');
    expect(js).toContain('es.object.values');
    expect(js).toContain('es.math.trunc');
    expect(js).toContain('es.string.pad-start');
    expect(js).toContain('es.array.find-last');
    expect(js).toContain('es.weak-map');

    const runner = join(fixture.dir, 'run-multi-module-top-level.cjs');
    await writeFile(
      runner,
      `
        Object.values = undefined;
        Math.trunc = undefined;
        String.prototype.padStart = undefined;
        Array.prototype.findLast = undefined;
        globalThis.WeakMap = undefined;
        require(${JSON.stringify(outFile)});
      `,
    );
    const run = await runNode(runner);
    expect(run.stdout).toBe('multi-top-level value|2|07|2|weak');
  });

  test('splitting keeps runtime prelude before on-demand chunks', async () => {
    const fixture = await createFixture({
      'package.json': '{"type":"module"}',
      'main.ts': `
        import("./lazy").then((mod) => {
          console.log("split", mod.value());
        });
      `,
      'lazy.ts': `
        export function value() {
          return "x-x".replaceAll("x", "y");
        }
      `,
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, 'dist');
    const bundle = await runZntcInDir(
      fixture.dir,
      [
        '--bundle',
        join(fixture.dir, 'main.ts'),
        '--outdir',
        outDir,
        '--format=esm',
        '--platform=node',
        '--target=es5',
        '--splitting',
        '--runtime-polyfills=auto',
        '--runtime-target=ios_saf 12',
      ],
      { bin: 'js' },
    );
    expect(bundle.exitCode).toBe(0);

    const main = await readFile(join(outDir, 'main.js'), 'utf-8');
    expect(main).toContain('es.string.replace-all');

    const runner = join(fixture.dir, 'run-split.mjs');
    await writeFile(
      runner,
      `
        String.prototype.replaceAll = undefined;
        await import(${JSON.stringify(`./dist/main.js`)});
      `,
    );
    const run = await runNode(runner);
    expect(run.stdout).toBe('split y-y');
  });

  test('multi-entry splitting imports shared runtime prelude call symbols', async () => {
    const fixture = await createFixture({
      'package.json': '{"type":"module"}',
      'entry-a.ts': `
        export const done = import("./lazy-a")
          .then((mod) => mod.value())
          .then((value) => console.log("entry-a", value));
      `,
      'entry-b.ts': `
        console.log("entry-b", "ok");
      `,
      'lazy-a.ts': `
        export function value() {
          return Promise.resolve(["m", "n"].at(-1)).then((last) =>
            Object.hasOwn({ n: 1 }, last) ? last : "missing"
          );
        }
      `,
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, 'dist');
    const bundle = await runZntcInDir(
      fixture.dir,
      [
        '--bundle',
        join(fixture.dir, 'entry-a.ts'),
        join(fixture.dir, 'entry-b.ts'),
        '--outdir',
        outDir,
        '--format=esm',
        '--platform=node',
        '--target=es5',
        '--splitting',
        '--runtime-polyfills=auto',
        '--runtime-target=safari 5',
      ],
      { bin: 'js' },
    );
    expect(bundle.exitCode).toBe(0);

    const runner = join(fixture.dir, 'run-multi-entry-split.mjs');
    await writeFile(
      runner,
      `
        Array.prototype.at = undefined;
        Object.hasOwn = undefined;
        globalThis.Promise = undefined;
        await import(${JSON.stringify(`./dist/entry-b.js`)});
        const entryA = await import(${JSON.stringify(`./dist/entry-a.js`)});
        await entryA.done;
      `,
    );
    const run = await runNode(runner);
    expect(run.stdout).toBe('entry-b ok\nentry-a n');
  });
});
