// POST /open-url — RN runtime 의 "open in browser" 액션. body { url } 받아서
// platform native opener 로 spawn (darwin: open, win32: cmd start, linux: xdg-open).

import { spawn } from 'node:child_process';
import type { IncomingMessage, ServerResponse } from 'node:http';

import { readJsonBody, sendJson } from '../http-utils.ts';

export function isOpenUrlRoute(pathname: string, method: string | undefined): boolean {
  return pathname === '/open-url' && method === 'POST';
}

interface PlatformOpener {
  command: string;
  args(target: string): string[];
}

function resolveOpener(platform: NodeJS.Platform = process.platform): PlatformOpener {
  if (platform === 'darwin') return { command: 'open', args: (t) => [t] };
  if (platform === 'win32') return { command: 'cmd', args: (t) => ['/c', 'start', '', t] };
  return { command: 'xdg-open', args: (t) => [t] };
}

export async function handleOpenUrl(
  req: IncomingMessage,
  res: ServerResponse,
  spawner: typeof spawn = spawn,
  platform: NodeJS.Platform = process.platform,
): Promise<void> {
  let body: { url?: unknown } = {};
  try {
    body = await readJsonBody<{ url?: unknown }>(req);
  } catch {
    sendJson(res, 400, { error: 'Invalid JSON body' });
    return;
  }
  const target = body.url;
  if (typeof target !== 'string' || target.length === 0) {
    sendJson(res, 400, { error: 'Invalid URL' });
    return;
  }
  try {
    const { command, args } = resolveOpener(platform);
    const child = spawner(command, args(target), { detached: true, stdio: 'ignore' });
    child.unref();
    sendJson(res, 200, { success: true });
  } catch {
    sendJson(res, 500, { error: 'Failed to open URL' });
  }
}
