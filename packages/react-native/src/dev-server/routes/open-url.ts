// POST /open-url — RN runtime 의 "open in browser" 액션. body { url } 받아서
// platform native opener 로 spawn (darwin: open, win32: rundll32, linux: xdg-open).

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
  // win32: `cmd /c start` 는 cmd.exe 가 인자를 재파싱해 `&`/`|` 등으로 명령 인젝션이
  // 가능하다(shell:false 여도). rundll32 는 인자를 셸로 재해석하지 않으므로 안전하게
  // 기본 브라우저로 URL 을 연다.
  if (platform === 'win32')
    return { command: 'rundll32', args: (t) => ['url.dll,FileProtocolHandler', t] };
  return { command: 'xdg-open', args: (t) => [t] };
}

const ALLOWED_PROTOCOLS = new Set(['http:', 'https:']);

// "open in browser" 액션의 안전한 입력인지 검증.
// - http/https 만 허용 (file:// 임의 파일 오픈, javascript:/커스텀 스킴 등 차단).
// - 제어문자·공백·따옴표·백슬래시 거부: 정상 인코딩된 http(s) URL 엔 없는 문자이며,
//   OS opener 의 명령줄 인자 구성/파싱 오용을 막는 추가 방어선.
function isSafeBrowserUrl(target: string): boolean {
  for (let i = 0; i < target.length; i += 1) {
    const c = target.charCodeAt(i);
    // 0x20=space 이하(제어문자/공백), 0x22=", 0x27=', 0x5c=\
    if (c <= 0x20 || c === 0x22 || c === 0x27 || c === 0x5c) return false;
  }
  let parsed: URL;
  try {
    parsed = new URL(target);
  } catch {
    return false;
  }
  return ALLOWED_PROTOCOLS.has(parsed.protocol);
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
  if (!isSafeBrowserUrl(target)) {
    sendJson(res, 400, { error: 'URL must be an http(s) URL without control characters' });
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
