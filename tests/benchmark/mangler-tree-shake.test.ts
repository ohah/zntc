import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const ROOT = resolve(__dirname, '../..');
const ZNTC_BIN = join(ROOT, 'zig-out/bin/zntc');

interface ManglerStats {
  slot_count: number;
  slot_name_length_sum: number;
  name_counter_final: number;
  reserved_size: number;
  renamed_symbol_count: number;
}
interface ManglerReport {
  top_level: ManglerStats;
  top_level_reserved_pool: number;
  nested: { module_path: string; stats: ManglerStats }[];
  bundle_size_bytes: number;
  totals: ManglerStats;
}

function bundle(entrySrc: string): ManglerReport {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-mangle-shake-'));
  const entry = join(__dirname, `_mangle_shake_entry_${process.pid}.ts`);
  writeFileSync(entry, entrySrc);
  try {
    const out = join(dir, 'out.js');
    const reportPath = join(dir, 'report.json');
    const r = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        entry,
        '-o',
        out,
        '--minify',
        '--platform=node',
        `--mangle-report=${reportPath}`,
      ],
      { encoding: 'utf8', timeout: 120_000 },
    );
    if (r.status !== 0) throw new Error(`zntc failed (${r.status}): ${r.stderr}`);
    return JSON.parse(readFileSync(reportPath, 'utf8'));
  } finally {
    rmSync(dir, { recursive: true, force: true });
    try {
      rmSync(entry);
    } catch {}
  }
}

describe('mangle pool tree-shake awareness', () => {
  // 회귀 방지: tree-shake 후 dead 로 판정된 모듈의 top-level binding 이
  // mangle candidate 풀(짧은 이름 54자) 을 잠식하면 안 된다. 회귀 발생 시
  // lodash-es 의 slot_count 가 1200대로 급증한다 (fix 전 1203, 후 ~300).
  test('lodash-es: dead module bindings are excluded from candidate pool', () => {
    const report = bundle(`
import { groupBy, sortBy, uniq } from 'lodash-es';
console.log(groupBy, sortBy, uniq);
    `);

    // entry 가 named export 3개만 사용 → tree-shake 가 lodash 내부 모듈 대다수
    // (bind/curry/partial/wrapperLodash 등) 를 dead 로 판정해야 한다. 이 fix 가
    // 깨지면 모든 모듈의 top-level binding (~1200개) 이 candidate 로 들어와
    // 짧은 이름 풀 1글자 54개의 67% 가 emit 안 될 binding 에 낭비된다.
    expect(report.top_level.slot_count).toBeLessThan(500);
    // bundle 자체 sanity — fix 가 정상 동작하면 ~21KB.
    expect(report.bundle_size_bytes).toBeLessThan(23_000);
    // nested 통계가 빈 배열이면 mangle-report.recordNested 회귀 (PR 3228).
    expect(report.nested.length).toBeGreaterThan(0);
  });
});
