import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  applyCustomizeFrame,
  createSourceMapConsumer,
  extractCodeFrame,
  symbolicateFrame,
} from './symbolicate-source.ts';
import type { FrameInfo } from './types.ts';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zts-rn-symbolicate-'));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe('createSourceMapConsumer', () => {
  test('invalid JSON → null', async () => {
    expect(await createSourceMapConsumer('not json')).toBeNull();
  });

  test('valid sourcemap → consumer 반환', async () => {
    const map = JSON.stringify({
      version: 3,
      sources: ['input.js'],
      names: [],
      mappings: 'AAAA',
    });
    const consumer = await createSourceMapConsumer(map);
    expect(consumer).not.toBeNull();
    consumer?.destroy?.();
  });
});

interface FakeConsumer {
  originalPositionFor(input: { line: number; column: number }): {
    source: string | null;
    line: number | null;
    column: number | null;
    name: string | null;
  };
}

function fakeConsumer(
  fn: (
    line: number,
    column: number,
  ) => {
    source: string | null;
    line: number | null;
    column: number | null;
    name: string | null;
  },
): FakeConsumer {
  return { originalPositionFor: ({ line, column }) => fn(line, column) };
}

describe('symbolicateFrame', () => {
  test('file/lineNumber 누락 → frame fields fallback', () => {
    const consumer = fakeConsumer(() => ({
      source: 'x.ts',
      line: 1,
      column: 0,
      name: null,
    }));
    expect(symbolicateFrame(consumer as never, { methodName: 'foo' }, '/proj')).toEqual({
      file: null,
      methodName: 'foo',
      lineNumber: null,
      column: null,
    });
  });

  test('source null → 원본 frame fields 보존', () => {
    const consumer = fakeConsumer(() => ({
      source: null,
      line: null,
      column: null,
      name: null,
    }));
    expect(
      symbolicateFrame(consumer as never, { file: 'b.js', lineNumber: 5, column: 2 }, '/proj'),
    ).toEqual({
      file: 'b.js',
      methodName: null,
      lineNumber: 5,
      column: 2,
    });
  });

  test('relative source → projectRoot 기준 absolute', () => {
    const consumer = fakeConsumer(() => ({
      source: 'src/x.ts',
      line: 10,
      column: 4,
      name: 'foo',
    }));
    expect(
      symbolicateFrame(consumer as never, { file: 'b.js', lineNumber: 1, column: 0 }, '/proj'),
    ).toEqual({
      file: '/proj/src/x.ts',
      methodName: 'foo',
      lineNumber: 10,
      column: 4,
    });
  });

  test('absolute source → 그대로', () => {
    const consumer = fakeConsumer(() => ({
      source: '/abs/x.ts',
      line: 7,
      column: 3,
      name: null,
    }));
    expect(
      symbolicateFrame(
        consumer as never,
        { file: 'b.js', lineNumber: 1, column: 0, methodName: 'orig' },
        '/proj',
      ).file,
    ).toBe('/abs/x.ts');
  });

  test('consumer throw → frame fallback', () => {
    const consumer = {
      originalPositionFor() {
        throw new Error('boom');
      },
    };
    expect(
      symbolicateFrame(consumer as never, { file: 'b.js', lineNumber: 1, column: 0 }, '/proj').file,
    ).toBe('b.js');
  });
});

describe('extractCodeFrame', () => {
  test('file 없음 → null', async () => {
    expect(
      await extractCodeFrame([
        { file: null, methodName: null, lineNumber: 1, column: 0 } as FrameInfo,
      ]),
    ).toBeNull();
  });

  test('.bundle 경로 skip', async () => {
    expect(
      await extractCodeFrame([
        { file: '/x/index.bundle', methodName: null, lineNumber: 1, column: 0 } as FrameInfo,
      ]),
    ).toBeNull();
  });

  test('정상 — ±2 줄 발췌', async () => {
    const path = join(dir, 'x.ts');
    writeFileSync(path, 'L1\nL2\nL3\nL4\nL5\nL6\n');
    const result = await extractCodeFrame([
      { file: path, methodName: null, lineNumber: 4, column: 0 } as FrameInfo,
    ]);
    expect(result?.fileName).toBe(path);
    expect(result?.location.row).toBe(4);
    expect(result?.content.split('\n')).toEqual(['L2', 'L3', 'L4', 'L5', 'L6']);
  });

  test('readFile fail → 다음 frame 시도', async () => {
    const ok = join(dir, 'ok.ts');
    writeFileSync(ok, 'A\nB\nC\n');
    const result = await extractCodeFrame([
      { file: '/nonexistent.ts', methodName: null, lineNumber: 1, column: 0 } as FrameInfo,
      { file: ok, methodName: null, lineNumber: 2, column: 0 } as FrameInfo,
    ]);
    expect(result?.fileName).toBe(ok);
  });

  test('lineNumber 범위 외 → 다음 frame', async () => {
    const path = join(dir, 'y.ts');
    writeFileSync(path, 'only\n');
    expect(
      await extractCodeFrame([
        { file: path, methodName: null, lineNumber: 100, column: 0 } as FrameInfo,
      ]),
    ).toBeNull();
  });
});

describe('applyCustomizeFrame', () => {
  const frame: FrameInfo = { file: 'x', methodName: null, lineNumber: 1, column: 0 };

  test('customizeFrame 미지정 → frame 그대로', async () => {
    expect(await applyCustomizeFrame(frame, undefined)).toEqual(frame);
  });

  test('collapse:true → frame + collapse:true', async () => {
    const result = await applyCustomizeFrame(frame, async () => ({ collapse: true }));
    expect(result).toEqual({ ...frame, collapse: true });
  });

  test('collapse:false → frame 그대로 (collapse 키 없음)', async () => {
    expect(await applyCustomizeFrame(frame, async () => ({ collapse: false }))).toEqual(frame);
  });

  test('void 반환 → frame 그대로', async () => {
    expect(await applyCustomizeFrame(frame, async () => undefined)).toEqual(frame);
  });

  test('customizeFrame throw → frame 그대로 (swallow)', async () => {
    expect(
      await applyCustomizeFrame(frame, async () => {
        throw new Error('user error');
      }),
    ).toEqual(frame);
  });
});
