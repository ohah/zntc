import { expect, test } from 'bun:test';
import { join } from 'node:path';
import { realpathSync } from 'node:fs';
import vm from 'node:vm';
import { createFixture } from './helpers';
import { build } from '../../../packages/core/index';

type Fixture = {
  label: string;
  modules: Record<string, string>;
  entryImport: string;
  entryExpression: string;
  routeImport: string;
  routeExpression: string;
  expectedEntry: unknown;
  expectedRoute: unknown;
  globals?: Record<string, unknown>;
  expectedGlobals?: Record<string, unknown>;
};

const fixtures: Fixture[] = [
  {
    label: 'direct namespace re-export',
    modules: {
      'shared.ts': "export const value = () => 'A';",
      'barrel.ts': "export * as api from './shared';",
    },
    entryImport: "import { api } from './barrel';",
    entryExpression: 'api.value()',
    routeImport: "import { api } from './barrel';",
    routeExpression: 'api.value()',
    expectedEntry: 'A',
    expectedRoute: 'A',
  },
  {
    label: 'renamed namespace export',
    modules: {
      'shared.ts': "export const label = () => 'RENAMED';",
      'barrel.ts': "export * as toolbox from './shared';",
    },
    entryImport: "import { toolbox } from './barrel';",
    entryExpression: 'toolbox.label()',
    routeImport: "import { toolbox } from './barrel';",
    routeExpression: 'toolbox.label()',
    expectedEntry: 'RENAMED',
    expectedRoute: 'RENAMED',
  },
  {
    label: 'two namespace aliases share one target owner',
    modules: {
      'shared.ts': "export const value = () => 'DUAL';",
      'barrel.ts': "export * as left from './shared'; export * as right from './shared';",
    },
    entryImport: "import { left } from './barrel';",
    entryExpression: 'left.value()',
    routeImport: "import { right } from './barrel';",
    routeExpression: 'right.value()',
    expectedEntry: 'DUAL',
    expectedRoute: 'DUAL',
  },
  {
    label: 'namespace export through a named re-export hop',
    modules: {
      'shared.ts': "export const value = () => 'HOP';",
      'barrel.ts': "export * as api from './shared';",
      'mid.ts': "export { api as renamed } from './barrel';",
    },
    entryImport: "import { renamed } from './mid';",
    entryExpression: 'renamed.value()',
    routeImport: "import { renamed } from './mid';",
    routeExpression: 'renamed.value()',
    expectedEntry: 'HOP',
    expectedRoute: 'HOP',
  },
  {
    label: 'namespace import re-exported as a local binding',
    modules: {
      'shared.ts': "export const value = () => 'LOCAL-NS';",
      'barrel.ts': "import * as api from './shared'; export { api };",
    },
    entryImport: "import { api } from './barrel';",
    entryExpression: 'api.value()',
    routeImport: "import { api } from './barrel';",
    routeExpression: 'api.value()',
    expectedEntry: 'LOCAL-NS',
    expectedRoute: 'LOCAL-NS',
  },
  {
    label: 'same basename providers keep distinct namespace owners',
    modules: {
      'left/shared.ts': "export const leftValue = 'LEFT';",
      'right/shared.ts': "export const rightValue = 'RIGHT';",
      'barrel.ts':
        "export * as left from './left/shared'; export * as right from './right/shared';",
    },
    entryImport: "import { left } from './barrel';",
    entryExpression: "Object.keys(left).sort().join(',')",
    routeImport: "import { right } from './barrel';",
    routeExpression: "Object.keys(right).sort().join(',')",
    expectedEntry: 'leftValue',
    expectedRoute: 'rightValue',
  },
  {
    label: 'default and named members on a namespace export',
    modules: {
      'shared.ts':
        "function main() { return 'DEFAULT'; } export { main as default }; export const label = () => 'NAMED';",
      'barrel.ts': "export * as api from './shared';",
    },
    entryImport: "import { api } from './barrel';",
    entryExpression: 'api.default()',
    routeImport: "import { api } from './barrel';",
    routeExpression: 'api.label()',
    expectedEntry: 'DEFAULT',
    expectedRoute: 'NAMED',
  },
  {
    label: 'two namespace members retain one aliased source binding',
    modules: {
      'shared.ts': "const value = () => 'ALIAS'; export { value as left, value as right };",
      'barrel.ts': "export * as api from './shared';",
    },
    entryImport: "import { api } from './barrel';",
    entryExpression: "Object.keys(api).sort().join(',')",
    routeImport: "import { api } from './barrel';",
    routeExpression: "Object.keys(api).sort().join(',')",
    expectedEntry: 'left,right',
    expectedRoute: 'left,right',
  },
  {
    label: 'namespace aliases avoid a free global with the generated base name',
    modules: {
      'shared.ts': "export const value = () => 'FREE-GLOBAL';",
      'barrel.ts': "export * as api from './shared';",
    },
    entryImport: "import { api } from './barrel';",
    entryExpression: 'api.value()',
    routeImport: "import { api } from './barrel';",
    routeExpression: 'api.value()',
    expectedEntry: 'FREE-GLOBAL',
    expectedRoute: 'FREE-GLOBAL',
    globals: { shared_ns: 'KEEP' },
    expectedGlobals: { freeBefore: 'KEEP', shared_ns: 'KEEP' },
  },
  {
    label: 'reserved export key inside the namespace object',
    modules: {
      'shared.ts': "const remove = () => 'RESERVED'; export { remove as delete };",
      'barrel.ts': "export * as api from './shared';",
    },
    entryImport: "import { api } from './barrel';",
    entryExpression: 'api.delete()',
    routeImport: "import { api } from './barrel';",
    routeExpression: 'api.delete()',
    expectedEntry: 'RESERVED',
    expectedRoute: 'RESERVED',
  },
];

test(
  'lazy namespace re-export hands generated bindings to their exact owners',
  { timeout: 120_000 },
  async () => {
    expect(fixtures).toHaveLength(10);
    for (const fixture of fixtures) {
      const sourceFiles = {
        ...fixture.modules,
        'Route.ts': `${fixture.routeImport}\nexport function read() { return ${fixture.routeExpression}; }`,
        'entry.ts': [
          fixture.entryImport,
          ...(fixture.label.includes('free global') ? ['globalThis.freeBefore = shared_ns;'] : []),
          `globalThis.entryValue = ${fixture.entryExpression};`,
          "globalThis.loadRoute = () => import('./Route');",
        ].join('\n'),
      };
      const temporary = await createFixture(sourceFiles);
      try {
        const rootDir = realpathSync(temporary.dir);
        const options = {
          entryPoints: [join(rootDir, 'entry.ts')],
          platform: 'browser' as const,
          devMode: true,
          splitting: true,
          format: 'iife' as const,
          lazyCompilation: true,
          rootDir,
        };
        const base = await build(options);
        const seeds = (base.lazySeeds ?? [])
          .filter((seed) => seed.path.endsWith('Route.ts'))
          .map((seed) => seed.path);
        expect(seeds, fixture.label).toHaveLength(1);

        const result = await build({ ...options, lazyForceParse: seeds });
        expect(result.errors ?? [], fixture.label).toHaveLength(0);
        const outputFiles = result.outputFiles ?? [];
        const entry = outputFiles.find((file) => file.path.endsWith('entry.js'));
        const route = outputFiles.find(
          (file) => file.path.includes('Route-') && file.path.endsWith('.js'),
        );
        expect(entry, fixture.label).toBeDefined();
        expect(route, fixture.label).toBeDefined();
        const context: Record<string, unknown> = { console, ...fixture.globals };
        context.globalThis = context;
        const vmContext = vm.createContext(context);
        vm.runInContext(entry!.text, vmContext);
        vm.runInContext(route!.text, vmContext);

        expect(context.entryValue, fixture.label).toBe(fixture.expectedEntry);
        const modules = context.__zntc_mods as Record<string, unknown>;
        const requireModule = context.__zntc_require as (id: string) => { read: () => unknown };
        const routeId = Object.keys(modules).find((id) => /Route/.test(id));
        expect(routeId, fixture.label).toBeDefined();
        expect(requireModule(routeId!).read(), fixture.label).toBe(fixture.expectedRoute);
        for (const [name, value] of Object.entries(fixture.expectedGlobals ?? {}))
          expect(context[name], `${fixture.label}: global ${name}`).toBe(value);
      } finally {
        await temporary.cleanup();
      }
    }
  },
);
