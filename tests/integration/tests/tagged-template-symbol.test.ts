import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = [
  {
    name: 'tagged-template cache names use the final standalone symbol set',
    source: `const _templateObject = 'source one';
const _templateObject2 = 'source two';
function tag(strings, value) { return strings[0] + value + strings[1]; }
function first() { return tag\`a\${1}b\`; }
function second() { return tag\`c\${2}d\`; }
console.log(first(), second(), _templateObject, _templateObject2);
`,
  },
  {
    name: 'escaped direct eval identifiers reserve early tagged-template cache names',
    source: `const _templateObject = 'source';
function tag(strings) { return strings[0]; }
function read() {
  return eval('typeof \\u005ftemplateObject2') + ':' + tag\`safe\`;
}
console.log(read(), _templateObject);
`,
  },
] as const;

describe('tagged-template cache symbol names (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixtureCase of cases) {
    for (const bundled of [false, true]) {
      for (const minify of [false, true]) {
        test(`${fixtureCase.name}: ${bundled ? 'bundle' : 'single-file'}, ${minify ? 'minify' : 'plain'}`, async () => {
          const fixture = await createFixture({
            'input.mjs': fixtureCase.source,
            'reference.mjs': fixtureCase.source,
          });
          cleanup = fixture.cleanup;
          const native = spawnSync('node', [join(fixture.dir, 'reference.mjs')], {
            encoding: 'utf8',
          });
          expect(native.status).toBe(0);

          const out = join(fixture.dir, 'out.cjs');
          const result = await runZntcInDir(fixture.dir, [
            ...(bundled ? ['--bundle'] : []),
            'input.mjs',
            '--target=es5',
            ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
            ...(bundled ? ['--platform=node', '--format=cjs'] : []),
            '-o',
            out,
          ]);
          expect(result.exitCode).toBe(0);

          const emitted = await Bun.file(out).text();
          expect(emitted).not.toContain('__zntc_template_object');
          if (!bundled && !minify && fixtureCase.name.includes('final standalone')) {
            expect(emitted).toContain('_templateObject3');
            expect(emitted).toContain('_templateObject4');
          }
          if (!bundled && !minify && fixtureCase.name.includes('escaped direct eval')) {
            expect(emitted).toContain('function _templateObject3');
            expect(emitted).not.toContain('function _templateObject2');
          }

          const runtime = spawnSync('node', [out], { encoding: 'utf8' });
          expect(runtime.status).toBe(0);
          expect(runtime.stdout).toBe(native.stdout);
        });
      }
    }
  }
});
