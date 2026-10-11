import { describe, test, expect } from 'bun:test';
import { createFixture, runNode, runZntc } from './helpers';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Regression: block 안 function declaration은 sloppy/Annex B 경로에서
 * function/var scope로 predeclare된다. 2차 방문 때 declaration name node에
 * predeclared symbol_id를 다시 붙이지 못하면 linker rename이 reference에만
 * 적용되어 `addException$1` 미선언 번들이 나온다.
 *
 * 실제 증상: React Native LogBox.js의 `addException` helper가 source module의
 * `addException` export와 충돌하면서 object literal/reference는 `addException$1`,
 * declaration은 `function addException`으로 emit되어
 * `Property 'addException$1' doesn't exist`가 발생.
 */
describe('bundle: block function declaration keeps canonical rename', () => {
  test('RN LogBox-style block function and source export name collision', async () => {
    const fixture = await createFixture({
      'entry.js': `
        import Box from './box.js';
        import { run } from './notification.js';
        Box.install();
        Box.addException({ message: 'direct' });
        run(2);
      `,
      'data.js': `
        export function addException(error) { console.log('exception:' + error.message); }
        export function setSelectedLog(index) { console.log('selected:' + index); }
      `,
      'box.js': `
        // @flow strict
        var Box;
        if (true) {
          const Data = require('./data');
          Box = {
            install(): void {
              global.RN$registerExceptionListener((error: {preventDefault: () => mixed}) => {
                error.preventDefault();
                addException(error);
              });
            },
            addException: addException,
          };
          function addException(error): void {
            Data.addException(error);
          }
        }
        export default Box;
      `,
      'notification.js': `
        import * as Data from './data';
        export function run(index) {
          Data.setSelectedLog(index);
        }
      `,
    });

    try {
      const out = join(fixture.dir, 'out.js');
      const result = await runZntc([
        '--bundle',
        '--platform=react-native',
        '--rn-platform=ios',
        join(fixture.dir, 'entry.js'),
        '-o',
        out,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      // The block function's declaration and both of its references (the
      // listener call and the object property) must agree on one final name,
      // and must not capture data.js's same-named export.
      const driver = join(fixture.dir, 'run.cjs');
      writeFileSync(
        driver,
        `globalThis.RN$registerExceptionListener = (cb) => cb({ message: 'listener', preventDefault() {} });\n` +
          `require(${JSON.stringify(out)});\n`,
      );
      const run = await runNode(driver);
      expect(run.stdout.trim().split('\n')).toEqual([
        'exception:listener',
        'exception:direct',
        'selected:2',
      ]);
    } finally {
      await fixture.cleanup();
    }
  });
});
