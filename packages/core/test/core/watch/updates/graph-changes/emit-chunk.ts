import {
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  watch,
  writeFileSync,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

// #3664: watch 증분 빌드에서 plugin 이 emit 한 *신규* chunk 모듈이 reparsed 에 누락돼 HMR diff 가
// 그 코드를 "no change" 로 drop → client 에 안 실리던 stale 버그의 회귀 가드.
//
// 시나리오: 초기 빌드엔 main 에 마커가 없어 worker 를 emit 하지 않는다(worker 는 graph 밖). 리빌드
// 때 main 을 편집해 마커를 넣으면 transform 이 worker 를 처음 emit → worker 가 *리빌드 중*
// injectEmittedChunks 로 신규 추가된다. fix 전: reparsed 누락 → updates 에서 빠짐. fix 후:
// post-renumber 인덱스로 reparsed 등록 → worker 코드가 rebuild updates(HMR 페이로드)에 실린다.
describe('watch() > rebuild updates > emit chunk (신규 emit 모듈 reparsed)', () => {
  test('리빌드 중 처음 emit 된 chunk 모듈이 HMR updates 에 실린다 (#3664)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-emit-'));
    let handle: ReturnType<typeof watch> | undefined;
    try {
      const workerPath = join(dir, 'worker.ts');
      // worker 는 실제 파일로 존재(emit id 가 resolve 돼야). 고유 마커 777 로 추적.
      writeFileSync(workerPath, 'export const w = 777;\nconsole.log(w);\n');
      // 초기 main: 마커 없음 → plugin 이 worker 를 emit 하지 않음.
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');

      const plugin: ZntcPlugin = {
        name: 'emit-on-marker',
        setup(build) {
          build.onTransform({ filter: /main\.ts$/ }, function (args: { code: string }) {
            // main 에 마커가 있을 때만 worker 를 별도 chunk 로 emit (절대경로 → resolve 불요).
            if (args.code.includes('EMIT_WORKER')) {
              this.emitFile({ type: 'chunk', id: workerPath });
            }
            return null;
          });
        },
      };

      const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
      const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
        graphChanged?: boolean;
        reparsedModules?: number;
      }>();

      handle = watch({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        splitting: true,
        devMode: true,
        collectModuleCodes: true,
        onReady() {
          readyDone();
        },
        onRebuild(event) {
          rebuildDone(event);
        },
      });

      await readyP; // 초기 빌드: worker 미emit (graph 밖).
      await new Promise((r) => setTimeout(r, 100));
      // 리빌드 트리거: main 에 마커 추가 → transform 이 worker 를 처음 emit.
      writeFileSync(join(dir, 'main.ts'), '// EMIT_WORKER\nexport const x = 1;\n');

      const event = await rebuildP;
      // 신규 emit 모듈 추가 = 그래프 변경 → 클라이언트 full reload 로 새 worker chunk 가 서빙된다.
      expect(event.graphChanged).toBe(true);
      // 핵심(fix 회귀 가드): 리빌드 중 처음 emit 된 worker 가 reparsed 에 포함돼야 한다. reparsed 는
      // main(편집됨) + worker(신규 emit) = 2. fix 누락 시 worker 는 injectEmittedChunks 밖에서
      // 추가돼 reparsed 에 안 들어가 main 만 = 1 → HMR diff 가 worker 코드를 drop(stale).
      expect(event.reparsedModules).toBeGreaterThanOrEqual(2);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 10000);
});
