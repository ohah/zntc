/**
 * RN MF 스파이크0 — JS/계약 자동 하니스 (네이티브 외 검증가능 부분).
 *
 * /simplify 빡센 검증 후 정직 재작성: **자가충족/tautological 체크 제거**.
 * 이 하니스가 *진짜로 기계 검증* 하는 것만 GREEN:
 *   - zntc 실 빌드가 컨테이너 + mf-manifest 산출
 *   - **globalThis 경로**(zntc 현 emit, 표준 webpack 규약) 컨테이너가
 *     get/init 보유 — 네이티브가 evaluate 후 globalThis 읽는 것과 동형
 *
 * **여기서 검증 안 됨(정직)** — 과거 초안이 GREEN 으로 과장했던 것:
 *   - ② 완료값=컨테이너 ABI: zntc 가 아직 ②-emit 안 함(번들 완료값=
 *     `undefined`, IIFE 가 반환 없음). 하니스가 wrap 으로 완료값을
 *     *조작*하면 globalThis 체크와 동일해질 뿐 → ②는 미검증.
 *     실검증 = zntc ②-emit 구현 + Hermes(B2). → CHECKLIST.
 *   - dual-ABI 공존(B7): webpack-origin 컨테이너 없음 → 미검증 → CHECKLIST.
 *   - 플러그인 hook: 실 @module-federation/runtime 등록 미실행 →
 *     형태 sketch 일 뿐 → CHECKLIST/실 RN host.
 *   - B3 싱글톤·실 loadRemote: `tests/integration/tests/
 *     mf-runtime-interop-smoke.test.ts` S2(GREEN, 별도 기계증명) 인용.
 *   - B1/.hbc·B2/.hbc 완료값·B5/B6 실RN·B9 off-device: Node≠Hermes.
 *
 * 실행: 리포 루트서 `bun spikes/rn-mf-spike0/harness/run.ts`
 *      (zig-out/bin/zntc 필요 — `zig build` 선행)
 */
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..', '..');
const ZNTC = join(repoRoot, 'zig-out', 'bin', 'zntc');

const log: string[] = [];
let failed = false;
const check = (step: string, cond: boolean, detail = '') => {
  log.push(`[verify] ${step.padEnd(24)} ${cond ? 'OK  ' : 'FAIL'} ${detail}`);
  if (!cond) failed = true;
};
const deferred = (step: string, why: string) =>
  log.push(`[defer ] ${step.padEnd(24)} →CHECKLIST ${why}`);

const work = mkdtempSync(join(tmpdir(), 'rn-spike0-'));
try {
  // 1. 실 zntc 로 remote 컨테이너 빌드 (사용자 빌드 경로 동형)
  cpSync(join(here, '..', 'remote'), join(work, 'remote'), { recursive: true });
  const remoteDir = join(work, 'remote');
  const dist = join(remoteDir, 'dist');
  execFileSync(
    ZNTC,
    ['--bundle', join(remoteDir, 'src', 'index.ts'), '--outdir', dist, '--format=iife', `--public-path=file://${dist}/`],
    { cwd: remoteDir, stdio: 'pipe' },
  );
  const files = readdirSync(dist);
  const entryFile = files.find(
    (f) => f.endsWith('.js') && readFileSync(join(dist, f), 'utf8').includes('__zntc_mf_container'),
  );
  check('build:container-emit', !!entryFile, entryFile ?? '(none)');
  check('build:manifest', files.includes('mf-manifest.json'));
  if (!entryFile) throw new Error('container 미산출');
  const src = readFileSync(join(dist, entryFile), 'utf8');

  // 2. globalThis 경로 — zntc 현 emit. (indirect eval = 글로벌 스코프;
  //    get() 미호출이라 청크 동적 import 미발화). 이게 *유일하게* 진짜
  //    기계검증 가능한 ABI(zntc 가 실제 emit 하는 형태).
  const ieval = (0, eval);
  let gPath: any;
  try {
    gPath = ieval(`${src}\n;globalThis["__FEDERATION_remote_app:custom__"]`);
  } catch (e) {
    check('abi:globalThis:eval', false, String(e));
  }
  check(
    'abi:globalThis:shape',
    !!gPath && typeof gPath.get === 'function' && typeof gPath.init === 'function',
    'zntc emit 컨테이너 get/init 실재(네이티브 globalThis-read 경로 동형)',
  );

  // 3. 정직: zntc 번들의 *실제* 완료값 확인 — ②가 미검증임을 데이터로 박제.
  const rawCompletion = ieval(src); // 조작 없는 진짜 완료값
  check(
    'abi:completion-is-undefined',
    rawCompletion === undefined,
    'zntc 미 ②-emit 확인(IIFE 반환 없음=완료값 undefined). ②는 emit 변경+Hermes 필요 → 미검증',
  );

  // 4. 미검증분 명시(과거 초안이 GREEN 으로 과장했던 것 — 정직 강등)
  deferred('②완료값 ABI(.hbc/JS)', 'zntc ②-emit 미구현+Node≠Hermes (B2)');
  deferred('dual-ABI 공존(B7)', 'webpack-origin 컨테이너 부재');
  deferred('플러그인 hook', '실 @mf/runtime 등록 미실행(형태 sketch)');
  deferred('B3 싱글톤', 'mf-runtime-interop-smoke S2 GREEN 인용(별도 기계증명)');
  deferred('B1/B5/B6/B9', 'Node≠Hermes — 실 RN 만');
} finally {
  rmSync(work, { recursive: true, force: true });
}

console.log(log.join('\n'));
console.log(
  failed
    ? '\nHARNESS: FAIL — 위 [verify] FAIL 확인'
    : '\nHARNESS: PASS — *진짜 기계검증분만* GREEN: zntc 컨테이너/매니페스트 산출 +\n' +
      '  globalThis-경로 컨테이너 형태 + zntc 미-②-emit 사실 확인. [defer] 항목은\n' +
      '  CHECKLIST(사용자 실 RN)·인용 증거로 분리 — 하니스가 검증했다 주장 안 함.',
);
process.exit(failed ? 1 : 0);
