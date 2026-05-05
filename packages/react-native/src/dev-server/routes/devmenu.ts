// POST/GET /devmenu — RN runtime open dev menu. Metro 호환: HTTP 응답 OK + ws
// broadcast `devMenu`.

import type { IncomingMessage, ServerResponse } from 'node:http';

import { sendText } from '../http-utils.ts';
import type { Broadcast } from '../types.ts';

export function isDevMenuRoute(pathname: string): boolean {
  return pathname === '/devmenu';
}

export function handleDevMenu(
  _req: IncomingMessage,
  res: ServerResponse,
  broadcast: Broadcast,
): void {
  broadcast('devMenu');
  sendText(res, 200, 'OK');
}
