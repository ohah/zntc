// #3803 — `BuildOptionsCommon.skipInitialOutput` 은 watch()-only. build()/buildSync()
// 가 무시하지만 사용자가 잘못 전달하면 silent. console.warn 으로 surface.

import { describe, expect, test, mkdtempSync, writeFileSync, rmSync, join, tmpdir } from './helpers';
import { build, buildSync } from '../../../index';

describe('build*/skipInitialOutput silent ignore warn (#3803)', () => {
  test('buildSync({skipInitialOutput:true}) → stderr warn 출력', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-skip-warn-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    const origWarn = console.warn;
    const captured: string[] = [];
    console.warn = (msg: string) => captured.push(String(msg));
    try {
      buildSync({ entryPoints: [join(dir, 'entry.ts')], skipInitialOutput: true });
      expect(captured.some((m) => m.includes('skipInitialOutput'))).toBe(true);
      expect(captured.some((m) => m.includes('buildSync'))).toBe(true);
    } finally {
      console.warn = origWarn;
      rmSync(dir, { recursive: true });
    }
  });

  test('build({skipInitialOutput:true}) → stderr warn 출력', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-skip-warn-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    const origWarn = console.warn;
    const captured: string[] = [];
    console.warn = (msg: string) => captured.push(String(msg));
    try {
      await build({ entryPoints: [join(dir, 'entry.ts')], skipInitialOutput: true });
      expect(captured.some((m) => m.includes('skipInitialOutput'))).toBe(true);
      expect(captured.some((m) => m.includes('build()'))).toBe(true);
    } finally {
      console.warn = origWarn;
      rmSync(dir, { recursive: true });
    }
  });

  test('skipInitialOutput 미지정 → warn 없음', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-skip-warn-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    const origWarn = console.warn;
    const captured: string[] = [];
    console.warn = (msg: string) => captured.push(String(msg));
    try {
      buildSync({ entryPoints: [join(dir, 'entry.ts')] });
      expect(captured.some((m) => m.includes('skipInitialOutput'))).toBe(false);
    } finally {
      console.warn = origWarn;
      rmSync(dir, { recursive: true });
    }
  });
});
