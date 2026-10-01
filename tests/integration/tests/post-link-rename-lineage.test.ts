import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

// #4804: a post-link const materialization re-analyzes adapters.js after both
// its default-export facade and a colliding forEach binding have been renamed.
// The runtime result checks that the carry-over preserves both identities.
const VARIANTS = [
  { name: '기본 번들', flags: [] },
  { name: 'ES5 minify-syntax', flags: ['--target=es5', '--minify-syntax'] },
];

describe('post-link rename identity carry-over (#4819)', () => {
  for (const variant of VARIANTS) {
    test(`#4804 export default 충돌을 실행 결과로 검증 — ${variant.name}`, async () => {
      const fixture = await createFixture({
        'num.js': 'export const LIMIT = 5;',
        'utils.js': 'function forEach() { return "u"; } export default { forEach };',
        'adapters.js':
          'import { LIMIT } from "./num.js";\n' +
          'function forEach() { return "a"; }\n' +
          'function getAdapter() { return forEach() + LIMIT; }\n' +
          'export default { getAdapter };',
        'main.js':
          'import utils from "./utils.js";\n' +
          'import adapters from "./adapters.js";\n' +
          'console.log(utils.forEach(), adapters.getAdapter());',
      });
      try {
        const output = join(fixture.dir, 'out.cjs');
        const bundle = await runZntc([
          '--bundle',
          join(fixture.dir, 'main.js'),
          '--platform=node',
          '--format=cjs',
          '-o',
          output,
          ...variant.flags,
        ]);
        expect(bundle.exitCode, bundle.stderr).toBe(0);

        const result = await runNode(output);
        expect(result.stdout).toBe('u a5');
        expect(result.stderr).toBe('');
      } finally {
        await fixture.cleanup();
      }
    });
  }
});
