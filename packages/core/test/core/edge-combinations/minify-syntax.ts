import {
  afterAll,
  beforeAll,
  buildSync,
  describe,
  expect,
  join,
  runBundleStdout,
  test,
  writeFileSync,
} from '../helpers';
import { createEdgeCombinationFixture, type EdgeCombinationFixture } from './fixture';

describe('엣지 케이스 + 조합 보강: minify syntax', () => {
  let fixture: EdgeCombinationFixture;

  beforeAll(() => {
    fixture = createEdgeCombinationFixture();
  });

  afterAll(() => fixture.cleanup());

  test('minifySyntax: 죽은 분기 참조 감산이 살아있는 const 함수 선언을 제거하지 않음', async () => {
    writeFileSync(
      join(fixture.dir, 'dead-branch-function-ref.js'),
      [
        'const DEBUG_NETWORK_SEND_DELAY = false;',
        'function send(data) {',
        '  let nativeResponseType = "text";',
        '  const doSend = () => {',
        '    globalThis.result = nativeResponseType + ":" + data;',
        '  };',
        '  if (DEBUG_NETWORK_SEND_DELAY) {',
        '    setTimeout(doSend, DEBUG_NETWORK_SEND_DELAY);',
        '  } else {',
        '    doSend();',
        '  }',
        '}',
        'send("ok");',
        'console.log(globalThis.result);',
      ].join('\n'),
    );

    for (const options of [{ minifySyntax: true }, { minify: true }]) {
      const result = buildSync({
        entryPoints: [join(fixture.dir, 'dead-branch-function-ref.js')],
        bundle: true,
        format: 'iife',
        ...options,
      });

      expect(result.errors.length).toBe(0);
      await expect(runBundleStdout(result.outputFiles[0].text)).resolves.toBe('text:ok');
    }
  });
});
