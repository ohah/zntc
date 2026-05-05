// POST /symbolicate — RN runtime LogBox 가 stack trace 보낼 때 호출. lazy
// sourcemap → consumer → 각 frame 역매핑 + customizeFrame hook + first
// non-bundle frame 의 code frame.

import type { IncomingMessage, ServerResponse } from 'node:http';

import { readJsonBody, sendJson } from '../http-utils.ts';
import type { CustomizeFrame } from '../options.ts';
import { getCachedSourceMap, type PlatformStateRegistry } from '../platform-state.ts';
import {
  applyCustomizeFrame,
  createSourceMapConsumer,
  extractCodeFrame,
  normalizeFrame,
  symbolicateFrame,
  type SymbolicateRequest,
  type SymbolicateResponse,
} from '../symbolicate-source.ts';
import { resolvePlatform } from './_shared.ts';

export function isSymbolicateRoute(pathname: string, method: string | undefined): boolean {
  return pathname === '/symbolicate' && method === 'POST';
}

export async function handleSymbolicateRequest(
  req: IncomingMessage,
  res: ServerResponse,
  url: URL,
  registry: PlatformStateRegistry,
  defaultPlatform: 'ios' | 'android',
  projectRoot: string,
  customizeFrame: CustomizeFrame | undefined,
): Promise<void> {
  let body: SymbolicateRequest;
  try {
    body = await readJsonBody<SymbolicateRequest>(req);
  } catch {
    sendJson(res, 400, { error: 'Invalid JSON body' });
    return;
  }
  const stack = body.stack ?? [];

  const state = resolvePlatform(url, registry, defaultPlatform);
  const sourceMap = getCachedSourceMap(state);

  const fallback: SymbolicateResponse = {
    stack: stack.map(normalizeFrame),
    codeFrame: null,
  };
  if (!sourceMap) {
    sendJson(res, 200, fallback);
    return;
  }

  const consumer = await createSourceMapConsumer(sourceMap);
  if (!consumer) {
    sendJson(res, 200, fallback);
    return;
  }

  try {
    const symbolicated = await Promise.all(
      stack.map(async (frame) => {
        const resolved = symbolicateFrame(consumer, frame, projectRoot);
        return applyCustomizeFrame(resolved, customizeFrame);
      }),
    );
    const codeFrame = await extractCodeFrame(symbolicated);
    sendJson(res, 200, { stack: symbolicated, codeFrame } satisfies SymbolicateResponse);
  } finally {
    consumer.destroy?.();
  }
}
