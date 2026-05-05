// GET /status, /status.txt — Metro 호환 live check. RN runtime 이 packager 가
// 살아있는지 확인할 때 사용. Body: "packager-status:running".

import type { IncomingMessage, ServerResponse } from "node:http";

import { sendText } from "../http-utils.ts";

const STATUS_BODY = "packager-status:running";

export function isStatusRoute(pathname: string): boolean {
  return pathname === "/status" || pathname === "/status.txt";
}

export function handleStatus(
  _req: IncomingMessage,
  res: ServerResponse,
  projectRoot: string,
): void {
  res.setHeader("X-React-Native-Project-Root", projectRoot);
  sendText(res, 200, STATUS_BODY);
}
