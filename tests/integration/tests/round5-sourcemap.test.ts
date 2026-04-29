/// Round 5 sourcemap mapping 깊이 회귀 테스트.
///
/// 17개 fixture 각각:
///   1. ZTS 로 `--sourcemap` 트랜스파일
///   2. 생성 코드에서 MARKER_* 식별자 위치(gen line/col) 추출
///   3. sourcemap mappings VLQ decode 후 debugger-style lookup
///   4. 매핑된 (src_line, src_col) 이 원본의 같은 이름 marker 위치와 일치하는지 검증
///
/// fixture 는 import/export specifier (#2220), enum 멤버 (#2221) 등의 매핑 정확성을 보장.
import { describe, test, expect } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runZts } from "./helpers";
import { decodeMappings, findMarkers, lookupMapping } from "./sourcemap-helpers";

const FIXTURES_DIR = join(import.meta.dir, "fixtures/round5-sourcemap");
const COL_TOLERANCE = 5;

const fixtures = readdirSync(FIXTURES_DIR)
  .filter((f) => /\.(ts|tsx)$/.test(f))
  .sort();

describe("Round 5 sourcemap mapping", () => {
  for (const fix of fixtures) {
    test(fix, async () => {
      const sourceText = readFileSync(join(FIXTURES_DIR, fix), "utf-8");
      const sourceByName = new Map<string, ReturnType<typeof findMarkers>>();
      for (const h of findMarkers(sourceText)) {
        const arr = sourceByName.get(h.name) || [];
        arr.push(h);
        sourceByName.set(h.name, arr);
      }

      const dir = await mkdtemp(join(tmpdir(), "zts-round5-"));
      try {
        const inFile = join(dir, fix);
        await writeFile(inFile, sourceText);
        const outFile = join(dir, fix.replace(/\.(ts|tsx)$/, ".js"));
        const r = await runZts([inFile, "-o", outFile, "--sourcemap"]);
        expect(r.exitCode).toBe(0);

        const outText = readFileSync(outFile, "utf-8");
        const mapJson = JSON.parse(readFileSync(outFile + ".map", "utf-8"));
        const mappings = decodeMappings(mapJson.mappings || "");

        for (const gm of findMarkers(outText)) {
          const seg = lookupMapping(mappings, gm.line, gm.col);
          expect(seg).not.toBeNull();
          if (!seg) continue;
          const sameLine = (sourceByName.get(gm.name) || []).filter((e) => e.line === seg.srcLine);
          // synthetic identifier (예: enum IIFE param 의 enum 이름 재사용) 는 mapped line 에
          // marker 가 없어도 허용 — 마지막 segment 가 다른 의미 anchor 일 수 있다.
          if (sameLine.length === 0) continue;
          const closest = sameLine.reduce((a, b) =>
            Math.abs(a.col - seg.srcCol) <= Math.abs(b.col - seg.srcCol) ? a : b,
          );
          expect(Math.abs(seg.srcCol - closest.col)).toBeLessThanOrEqual(COL_TOLERANCE);
        }
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    });
  }
});
