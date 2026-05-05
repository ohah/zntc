// source-map 기반 stack frame 역매핑 + customizeFrame hook + code frame 추출.
// SourceMapConsumer 는 dynamic import (source-map 0.7+ peer 영향 최소화). frame
// 별 customizeFrame 호출은 비동기 + 에러 swallow (Metro 호환).

import { readFile } from 'node:fs/promises';
import { resolve as pathResolve } from 'node:path';

import type { CustomizeFrame } from './options.ts';
import type { FrameInfo } from './types.ts';

export interface SymbolicateRequest {
  stack: Array<Partial<FrameInfo>>;
}

export interface SymbolicateCodeFrame {
  content: string;
  location: { row: number; column: number };
  fileName: string;
}

export interface SymbolicateResponse {
  stack: Array<FrameInfo & { collapse?: boolean }>;
  codeFrame: SymbolicateCodeFrame | null;
}

interface SourceMapConsumerLike {
  originalPositionFor(input: { line: number; column: number }): {
    source: string | null;
    line: number | null;
    column: number | null;
    name: string | null;
  };
  destroy?(): void;
}

/**
 * sourceMap JSON → SourceMapConsumer. source-map@^0.7 의 SourceMapConsumer 는
 * Promise<consumer>. 호출자가 try/finally 로 destroy 호출.
 */
export async function createSourceMapConsumer(
  sourceMapJson: string,
): Promise<SourceMapConsumerLike | null> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(sourceMapJson);
  } catch {
    return null;
  }
  // dynamic import — source-map peer dep miss 시 graceful fallback. npm types 와
  // runtime 시그니처 차이 때문에 unknown cast.
  try {
    const mod = (await import('source-map')) as unknown as {
      SourceMapConsumer: new (map: unknown) => unknown;
    };
    return await (new mod.SourceMapConsumer(parsed) as unknown as Promise<SourceMapConsumerLike>);
  } catch {
    return null;
  }
}

/** Partial frame → 모든 필드가 채워진 FrameInfo (null fallback). */
export function normalizeFrame(frame: Partial<FrameInfo>): FrameInfo {
  return {
    file: frame.file ?? null,
    methodName: frame.methodName ?? null,
    lineNumber: frame.lineNumber ?? null,
    column: frame.column ?? null,
  };
}

/** 단일 frame 역매핑. 매핑 실패 시 frame 그대로 (Metro 호환 — DevTools 가 fallback). */
export function symbolicateFrame(
  consumer: SourceMapConsumerLike,
  frame: Partial<FrameInfo>,
  projectRoot: string,
): FrameInfo {
  if (!frame.file || frame.lineNumber == null) return normalizeFrame(frame);
  try {
    const pos = consumer.originalPositionFor({
      line: frame.lineNumber,
      column: frame.column ?? 0,
    });
    if (pos.source == null || pos.line == null) return normalizeFrame(frame);
    const sourcePath = pos.source.startsWith('/')
      ? pos.source
      : pathResolve(projectRoot, pos.source);
    return {
      file: sourcePath,
      methodName: pos.name ?? frame.methodName ?? null,
      lineNumber: pos.line,
      column: pos.column ?? 0,
    };
  } catch {
    return normalizeFrame(frame);
  }
}

/**
 * frame 의 lineNumber 주변 ±2 줄 발췌 — RN runtime / DevTools 의 LogBox 가 보여줌.
 * `.bundle` 경로는 skip — bundled module 은 readable 한 source 가 아님.
 */
export async function extractCodeFrame(
  frames: ReadonlyArray<FrameInfo & { collapse?: boolean }>,
): Promise<SymbolicateCodeFrame | null> {
  for (const frame of frames) {
    if (!frame.file || frame.lineNumber == null) continue;
    if (frame.file.includes('.bundle')) continue;
    try {
      const source = await readFile(frame.file, 'utf-8');
      const lines = source.split('\n');
      const targetLine = frame.lineNumber - 1;
      if (targetLine < 0 || targetLine >= lines.length) continue;
      const startLine = Math.max(0, targetLine - 2);
      const endLine = Math.min(lines.length - 1, targetLine + 2);
      return {
        content: lines.slice(startLine, endLine + 1).join('\n'),
        location: { row: frame.lineNumber, column: frame.column ?? 0 },
        fileName: frame.file,
      };
    } catch {
      /* ignore — try next frame */
    }
  }
  return null;
}

/**
 * customizeFrame 호출 후 collapse 적용. errors are non-fatal (Metro parity).
 */
export async function applyCustomizeFrame(
  frame: FrameInfo,
  customizeFrame: CustomizeFrame | undefined,
): Promise<FrameInfo & { collapse?: boolean }> {
  if (!customizeFrame) return frame;
  try {
    const result = await customizeFrame(frame);
    if (result?.collapse) return { ...frame, collapse: true };
  } catch {
    /* user errors swallow */
  }
  return frame;
}
