// POST/GET /reload — RN runtime force reload. Metro 호환: HTTP 응답 OK + ws
// broadcast `reload` (cli-server-api messageSocketEndpoint).

import type { IncomingMessage, ServerResponse } from "node:http";

import { sendText } from "../http-utils.ts";
import type { Broadcast } from "../types.ts";

export function isReloadRoute(pathname: string): boolean {
  return pathname === "/reload";
}

export function handleReload(
  _req: IncomingMessage,
  res: ServerResponse,
  broadcast: Broadcast,
): void {
  broadcast("reload");
  sendText(res, 200, "OK");
}
