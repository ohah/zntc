import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

type HelperMode = 'automatic' | 'automatic-dev';

type LinkedHelperCase = {
  name: string;
  mode: HelperMode;
  shadows: string[];
  secondConsumerShadows?: string[];
  jsxExpression?: string;
  expectedJSX?: string;
};

const cases: LinkedHelperCase[] = [
  {
    name: 'single jsx helper import collides with its local name',
    mode: 'automatic',
    shadows: ['_jsx'],
    jsxExpression: '<div />',
    expectedJSX: 'jsx:div',
  },
  { name: 'jsx locals shadowed twice', mode: 'automatic', shadows: ['_jsx', '_jsx2'] },
  { name: 'jsxs locals shadowed twice', mode: 'automatic', shadows: ['_jsxs', '_jsxs2'] },
  {
    name: 'Fragment locals shadowed twice',
    mode: 'automatic',
    shadows: ['_Fragment', '_Fragment2'],
  },
  { name: 'jsx and jsxs locals collide together', mode: 'automatic', shadows: ['_jsx', '_jsxs'] },
  {
    name: 'jsx and Fragment locals collide together',
    mode: 'automatic',
    shadows: ['_jsx', '_Fragment'],
  },
  {
    name: 'jsxs and Fragment locals collide together',
    mode: 'automatic',
    shadows: ['_jsxs', '_Fragment'],
  },
  {
    name: 'all automatic helper locals and numbered neighbors collide',
    mode: 'automatic',
    shadows: ['_jsx', '_jsx2', '_jsxs', '_jsxs2', '_Fragment', '_Fragment2'],
  },
  {
    name: 'jsxDEV locals shadowed twice',
    mode: 'automatic-dev',
    shadows: ['_jsxDEV', '_jsxDEV2'],
  },
  {
    name: 'single jsxDEV helper import collides with its local name',
    mode: 'automatic-dev',
    shadows: ['_jsxDEV'],
    jsxExpression: '<div />',
    expectedJSX: 'dev:div',
  },
  {
    name: 'jsxDEV and Fragment locals collide together',
    mode: 'automatic-dev',
    shadows: ['_jsxDEV', '_Fragment'],
  },
  {
    name: 'two linked consumers shadow the same automatic helpers',
    mode: 'automatic',
    shadows: ['_jsx', '_jsxs', '_Fragment'],
    secondConsumerShadows: ['_jsx', '_jsxs2', '_Fragment2'],
  },
];

function consumerSource(
  shadows: string[],
  functionName: string,
  jsxExpression = '<><span /><div /></>',
): string {
  const declarations = shadows.map((name, index) => `const ${name} = ${index + 1};`).join('\n');
  const values = shadows.join(', ');
  return [
    declarations,
    `export function ${functionName}() { return [${jsxExpression}, ${values}].join('|'); }`,
  ]
    .filter(Boolean)
    .join('\n');
}

describe('linked JSX helper imports keep the provider canonical name (#4819)', () => {
  test.each(cases)(
    '$name',
    async ({ mode, shadows, secondConsumerShadows, jsxExpression, expectedJSX }) => {
      const runtimeSource =
        mode === 'automatic'
          ? [
              "export const Fragment = 'frag';",
              'export function jsx(tag) { return `jsx:${tag}`; }',
              "export function jsxs(tag, props) { return `jsxs:${tag}:${props.children.join(',')}`; }",
            ].join('\n')
          : [
              "export const Fragment = 'frag';",
              'export function jsxDEV(tag) { return `dev:${tag}`; }',
            ].join('\n');
      const runtimeFile =
        mode === 'automatic' ? 'runtime/jsx-runtime.js' : 'runtime/jsx-dev-runtime.js';
      const files: Record<string, string> = {
        [runtimeFile]: runtimeSource,
      };

      if (secondConsumerShadows) {
        files['first.tsx'] = consumerSource(shadows, 'first', jsxExpression);
        files['second.tsx'] = consumerSource(secondConsumerShadows, 'second', jsxExpression);
        files['entry.ts'] = [
          "import { first } from './first.tsx';",
          "import { second } from './second.tsx';",
          'console.log(first(), second());',
        ].join('\n');
      } else {
        files['view.tsx'] = consumerSource(shadows, 'view', jsxExpression);
        files['entry.ts'] = ["import { view } from './view.tsx';", 'console.log(view());'].join(
          '\n',
        );
      }

      const fixture = await createFixture(files);
      try {
        const output = join(fixture.dir, 'out.cjs');
        const result = await runZntcInDir(fixture.dir, [
          '--bundle',
          'entry.ts',
          '--target=esnext',
          '--platform=node',
          '--format=cjs',
          `--jsx=${mode}`,
          '--jsx-import-source=./runtime',
          '--minify-identifiers',
          '-o',
          output,
        ]);
        expect(result.exitCode, `${mode}: ${result.stderr}`).toBe(0);

        const runtime = spawnSync('node', [output], { encoding: 'utf8' });
        expect(runtime.status, `${mode}: ${runtime.stderr}`).toBe(0);
        const expectedNode =
          expectedJSX ?? (mode === 'automatic' ? 'jsxs:frag:jsx:span,jsx:div' : 'dev:frag');
        const expectedFirst = [expectedNode, ...shadows.map((_, index) => String(index + 1))].join(
          '|',
        );
        const expected = secondConsumerShadows
          ? `${expectedFirst} ${[
              expectedNode,
              ...secondConsumerShadows.map((_, index) => String(index + 1)),
            ].join('|')}\n`
          : `${expectedFirst}\n`;
        expect(runtime.stdout, `${mode}: ${runtime.stderr}`).toBe(expected);
      } finally {
        await fixture.cleanup();
      }
    },
  );
});
