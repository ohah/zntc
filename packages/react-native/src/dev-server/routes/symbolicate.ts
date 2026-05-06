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

  const debug = process.env.ZTS_DEBUG_SYMBOLICATE === '1';
  if (debug) {
    process.stderr.write(
      `[zts:rn-dev:debug] /symbolicate stack[${stack.length}] sourceMap=${sourceMap ? `len=${sourceMap.length}` : 'null'}\n`,
    );
    for (const f of stack.slice(0, 5)) {
      process.stderr.write(
        `[zts:rn-dev:debug]   in: file=${f.file} line=${f.lineNumber} col=${f.column} method=${f.methodName}\n`,
      );
    }
  }

  const fallback: SymbolicateResponse = {
    stack: stack.map(normalizeFrame),
    codeFrame: null,
  };
  if (!sourceMap) {
    if (debug) process.stderr.write('[zts:rn-dev:debug]   sourceMap miss → fallback\n');
    sendJson(res, 200, fallback);
    return;
  }

  const consumer = await createSourceMapConsumer(sourceMap);
  if (!consumer) {
    if (debug) process.stderr.write('[zts:rn-dev:debug]   consumer create fail → fallback\n');
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
    if (debug) {
      for (const f of symbolicated.slice(0, 5)) {
        process.stderr.write(
          `[zts:rn-dev:debug]   out: file=${f.file} line=${f.lineNumber} col=${f.column} method=${f.methodName}${f.collapse ? ' collapse=true' : ''}\n`,
        );
      }
      process.stderr.write(
        `[zts:rn-dev:debug]   codeFrame: ${codeFrame ? `${codeFrame.fileName}:${codeFrame.location.row}` : 'null'}\n`,
      );
    }
    sendJson(res, 200, { stack: symbolicated, codeFrame } satisfies SymbolicateResponse);
  } finally {
    consumer.destroy?.();
  }
}
