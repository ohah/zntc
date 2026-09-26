// 트랜스포머가 새로 만든 **사용자 변수** 식별자는 모두 원래 심볼을 가져야 한다 (#4760 게이트).
//
// 심볼이 빠지면 심볼 기준 리네임(es5 블록 스코핑·번들 이름 충돌 회피)이 그 노드만 옛 이름으로
// 남겨 없는 변수를 가리키고, **다른 변수의** 심볼이 붙으면 엉뚱한 변수를 따라간다. 식별자 생성은
// `scripts/audit-identifier-constructors.mjs` 가 분류 생성 함수로만 하게 막지만, 그 함수에 원래
// 노드를 잘못(`.none`·다른 노드) 넘기는 것까지는 못 막는다 — 이 테스트가 그 값 수준을 지킨다.
//
// 다운레벨 오라클 fixture 전체 × 낮추는 타깃으로 단일 파일 변환을 돌려 누락 검사기
// (`ZNTC_DEBUG_SYMBOL_COVERAGE`) 의 missing·wrong 이 모두 0 인지 본다. 변환기가 만든 합성 이름
// (`_this`·임시 변수·사용자 이름을 빌린 합성 바인딩)은 검사기가 뺀다.
import { describe, test, expect } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ZNTC_BIN } from './helpers';

const FIXTURE_DIR = join(import.meta.dir, '../fixtures/downlevel-oracle');
const TARGETS = ['es5', 'es2015', 'es2017', 'es2022'];

function runCoverage(
  file: string,
  target: string,
  outDir: string,
): { stderr: string; exitCode: number } {
  const proc = spawnSync(ZNTC_BIN, [file, `--target=${target}`, '-o', join(outDir, 'out.js')], {
    env: { ZNTC_DEBUG_SYMBOL_COVERAGE: '1', PATH: process.env.PATH ?? '/usr/bin:/bin' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  return { stderr: proc.stderr.toString(), exitCode: proc.status ?? -1 };
}

describe('symbol coverage gate (#4760)', () => {
  const fixtures = readdirSync(FIXTURE_DIR)
    .filter((f) => f.endsWith('.mjs'))
    .sort();

  test('오라클 fixture 전체에서 새 사용자 식별자의 심볼 누락·오류가 0', async () => {
    const outDir = mkdtempSync(join(tmpdir(), 'zntc-symcov-'));
    const problems: string[] = [];
    let runs = 0;
    try {
      for (const name of fixtures) {
        for (const target of TARGETS) {
          const { stderr, exitCode } = runCoverage(join(FIXTURE_DIR, name), target, outDir);
          if (exitCode !== 0) {
            problems.push(`${name} ${target}: exit=${exitCode} ${stderr.trim()}`);
            continue;
          }
          const lines = stderr.split('\n').filter((l) => l.includes('symbol-coverage'));
          if (lines.length !== 1) {
            problems.push(`${name} ${target}: expected one coverage report, got ${lines.length}`);
            continue;
          }
          const line = lines[0];
          runs++;
          const m = line.match(/missing=(\d+) wrong=(\d+)/);
          if (!m || m[1] !== '0' || m[2] !== '0') {
            const detail = stderr
              .split('\n')
              .filter((l) => /^\s+(missing|wrong) /.test(l))
              .join('; ');
            problems.push(
              `${name} ${target}: ${m ? `missing=${m[1]} wrong=${m[2]}` : line} ${detail}`,
            );
          }
        }
      }
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
    // 검사기가 실제로 돌았는지(출력 형식이 바뀌어 전부 건너뛰면 공허하게 통과한다).
    expect(problems).toEqual([]);
    expect(runs).toBe(fixtures.length * TARGETS.length);
  }, 600_000);
});
