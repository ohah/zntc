// @zntc/web 의 브라우저 inject 코드 — `<script type="module" src="/__zntc_app_dev_hmr__">`
// 로 dev server 가 내려보내는 텍스트. WebSocket 연결 + Shadow DOM error overlay
// + sourcemap 디코더 + runtime error capture 를 모두 포함.
//
// 이 파일 자체는 module 로 평가되지만 export 하는 `APP_DEV_HMR_CLIENT` 는
// **string** 이라 브라우저로 그대로 전송됨. template literal 안의 `${...}` 는
// module 평가 시점에 치환되어 protocol 상수 (`/__hmr`, "error" 같은 것) 가
// 정확히 박힘 — server 측 `@zntc/server/protocol` 과 single source of truth.

import { APP_DEV_HMR_WS_PATH, HMR_MSG } from '@zntc/server';

// biome-ignore format: 안의 코드는 브라우저 inject 텍스트라 zntc.mjs 의 원본 (#2539
// PR #4) 과 byte-for-byte parity 유지. 사소한 escape/들여쓰기 차이도 sourcemap
// VLQ 디코더 정확성에 영향.
export const APP_DEV_HMR_CLIENT = `
const socketProtocol = location.protocol === "https:" ? "wss:" : "ws:";
let overlay = null;
let closeOverlayOnEsc = null;
function hideOverlay() {
  if (closeOverlayOnEsc) document.removeEventListener("keydown", closeOverlayOnEsc);
  closeOverlayOnEsc = null;
  if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
  overlay = null;
}
function normalizeErrors(errors) {
  if (!Array.isArray(errors) || errors.length === 0) {
    return [{ file: "", message: "Unknown build error" }];
  }
  return errors.map((error) => {
    if (typeof error === "string") return { file: "", message: error };
    return {
      file: error && typeof error.file === "string" ? error.file : "",
      message: error && typeof error.message === "string" ? error.message : String(error),
    };
  });
}
function normalizeRuntimeError(error, file) {
  if (error && typeof error.stack === "string" && error.stack) {
    return { file: file || "", message: error.stack };
  }
  if (error && typeof error.message === "string" && error.message) {
    const name = typeof error.name === "string" && error.name ? error.name : "Error";
    return { file: file || "", message: name + ": " + error.message };
  }
  return { file: file || "", message: String(error || "Unknown runtime error") };
}
const sourceMapCache = new Map();
const sourceMapVlqChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function displaySourceName(source) {
  if (!source) return "";
  const clean = String(source).split("?")[0].split("#")[0];
  const slash = Math.max(clean.lastIndexOf("/"), clean.lastIndexOf("\\\\"));
  return slash >= 0 ? clean.slice(slash + 1) : clean;
}
function decodeSourceMapVlq(segment) {
  const values = [];
  let result = 0;
  let shift = 0;
  for (const ch of segment) {
    let digit = sourceMapVlqChars.indexOf(ch);
    if (digit < 0) return values;
    const continuation = digit & 32;
    digit &= 31;
    result += digit << shift;
    if (continuation) {
      shift += 5;
      continue;
    }
    const negative = result & 1;
    const value = result >> 1;
    values.push(negative ? -value : value);
    result = 0;
    shift = 0;
  }
  return values;
}
function parseSourceMapMappings(map) {
  if (map.__zntcParsedMappings) return map.__zntcParsedMappings;
  let source = 0;
  let originalLine = 0;
  let originalColumn = 0;
  let name = 0;
  const parsed = [];
  for (const line of String(map.mappings || "").split(";")) {
    let generatedColumn = 0;
    const segments = [];
    for (const segment of line.split(",")) {
      if (!segment) continue;
      const values = decodeSourceMapVlq(segment);
      if (values.length === 0) continue;
      generatedColumn += values[0];
      if (values.length >= 4) {
        source += values[1];
        originalLine += values[2];
        originalColumn += values[3];
        if (values.length >= 5) name += values[4];
        segments.push({ generatedColumn, source, originalLine, originalColumn });
      }
    }
    parsed.push(segments);
  }
  Object.defineProperty(map, "__zntcParsedMappings", { value: parsed });
  return parsed;
}
function findOriginalPosition(map, line, column) {
  const segments = parseSourceMapMappings(map)[line - 1];
  if (!segments || segments.length === 0) return null;
  let lo = 0;
  let hi = segments.length - 1;
  let best = null;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const segment = segments[mid];
    if (segment.generatedColumn <= column) {
      best = segment;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  best = best || segments[0];
  const source = map.sources && map.sources[best.source];
  if (!source) return null;
  const columnOffset = Math.max(0, column - best.generatedColumn);
  return {
    source: displaySourceName(source),
    line: best.originalLine + 1,
    column: best.originalColumn + columnOffset,
  };
}
async function loadSourceMapForGeneratedUrl(url) {
  const generatedUrl = new URL(url, location.href).href;
  if (sourceMapCache.has(generatedUrl)) return sourceMapCache.get(generatedUrl);
  const safeJson = async (response) => {
    try { return await response.json(); } catch (_) { return null; }
  };
  const promise = (async () => {
    const direct = await fetch(generatedUrl + ".map", { cache: "no-store" }).catch(() => null);
    if (direct && direct.ok) return safeJson(direct);
    const jsResponse = await fetch(generatedUrl, { cache: "no-store" }).catch(() => null);
    if (!jsResponse || !jsResponse.ok) return null;
    const code = await jsResponse.text();
    const match =
      code.match(/\\/\\/[#@]\\s*sourceMappingURL=([^\\n\\r]+)/) ||
      code.match(/\\/\\*[#@]\\s*sourceMappingURL=([^*]+)\\*\\//);
    if (!match) return null;
    const ref = match[1].trim();
    if (ref.startsWith("data:")) {
      const comma = ref.indexOf(",");
      if (comma < 0) return null;
      const meta = ref.slice(0, comma);
      const data = ref.slice(comma + 1);
      try {
        const json = meta.includes(";base64") ? atob(data) : decodeURIComponent(data);
        return JSON.parse(json);
      } catch (_) {
        return null;
      }
    }
    const mapResponse = await fetch(new URL(ref, generatedUrl).href, { cache: "no-store" }).catch(() => null);
    return mapResponse && mapResponse.ok ? safeJson(mapResponse) : null;
  })();
  sourceMapCache.set(generatedUrl, promise);
  return promise;
}
async function mapGeneratedLocation(url, line, column) {
  const map = await loadSourceMapForGeneratedUrl(url);
  return map ? findOriginalPosition(map, line, column) : null;
}
async function mapLocationText(text) {
  if (!text) return text;
  const match = String(text).match(/(https?:\\/\\/[^\\s)]+):(\\d+):(\\d+)/);
  if (!match) return text;
  const mapped = await mapGeneratedLocation(match[1], Number(match[2]), Number(match[3]));
  if (!mapped) return text;
  return String(text).replace(match[0], mapped.source + ":" + mapped.line + ":" + mapped.column);
}
async function mapStackTrace(stack) {
  if (typeof stack !== "string") return stack;
  const lines = await Promise.all(stack.split("\\n").map(mapLocationText));
  return lines.join("\\n");
}
async function normalizeRuntimeErrorWithSourceMap(error, file) {
  const item = normalizeRuntimeError(error, file);
  item.file = await mapLocationText(item.file);
  item.message = await mapStackTrace(item.message);
  return item;
}
async function showRuntimeOverlay(error, file) {
  let item;
  try {
    item = await normalizeRuntimeErrorWithSourceMap(error, file);
  } catch (_) {
    item = normalizeRuntimeError(error, file);
  }
  showOverlay([item], "Runtime Error");
}
function showOverlay(errors, titleText = "Build Error") {
  hideOverlay();
  const items = normalizeErrors(errors);
  overlay = document.createElement("div");
  overlay.id = "zntc-error-overlay";
  const root = overlay.attachShadow({ mode: "open" });
  const style = document.createElement("style");
  style.textContent = ":host{position:fixed;inset:0;z-index:2147483647;display:block;--font:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;--red:#fb7185;--text:#f8fafc;--blue:#93c5fd;--window:#181818;}" +
    ".backdrop{position:fixed;inset:0;overflow:auto;padding:32px;box-sizing:border-box;background:rgba(0,0,0,.66);font:14px/1.5 var(--font);color:var(--text);}" +
    ".window{max-width:980px;margin:0 auto;background:var(--window);border-top:8px solid var(--red);border-radius:6px 6px 8px 8px;box-shadow:0 19px 38px rgba(0,0,0,.30),0 15px 12px rgba(0,0,0,.22);overflow:hidden;}" +
    ".header{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:18px 20px;border-bottom:1px solid rgba(255,255,255,.12);}" +
    ".title{font-size:18px;font-weight:700;color:#fecdd3;}" +
    ".close{width:30px;height:30px;border:1px solid rgba(255,255,255,.25);border-radius:4px;background:#111827;color:var(--text);cursor:pointer;font:18px/1 var(--font);}" +
    ".card{padding:18px 20px;border-top:1px solid rgba(255,255,255,.08);}" +
    ".file{margin-bottom:10px;color:var(--blue);word-break:break-all;}" +
    ".message{margin:0;white-space:pre-wrap;color:#fff;word-break:break-word;font:14px/1.5 var(--font);}";
  const backdrop = document.createElement("div");
  backdrop.className = "backdrop";
  const panel = document.createElement("div");
  panel.className = "window";
  panel.onclick = (event) => event.stopPropagation();
  const header = document.createElement("div");
  header.className = "header";
  const title = document.createElement("div");
  title.className = "title";
  title.textContent = titleText;
  const close = document.createElement("button");
  close.type = "button";
  close.textContent = "x";
  close.className = "close";
  close.setAttribute("aria-label", "Close error overlay");
  close.onclick = hideOverlay;
  header.appendChild(title);
  header.appendChild(close);
  panel.appendChild(header);
  for (const item of items) {
    const card = document.createElement("div");
    card.className = "card";
    if (item.file) {
      const file = document.createElement("div");
      file.className = "file";
      file.textContent = item.file;
      card.appendChild(file);
    }
    const message = document.createElement("pre");
    message.className = "message";
    message.textContent = item.message;
    card.appendChild(message);
    panel.appendChild(card);
  }
  backdrop.appendChild(panel);
  root.appendChild(style);
  root.appendChild(backdrop);
  closeOverlayOnEsc = (event) => {
    if (event.key === "Escape" || event.code === "Escape") hideOverlay();
  };
  document.addEventListener("keydown", closeOverlayOnEsc);
  (document.body || document.documentElement).appendChild(overlay);
}
globalThis.__zntc_show_error_overlay = showOverlay;
globalThis.__zntc_clear_error_overlay = hideOverlay;
if (!globalThis.__zntc_runtime_listeners_attached) {
  globalThis.__zntc_runtime_listeners_attached = true;
  window.addEventListener("error", (event) => {
    const file = event.filename ? event.filename + ":" + event.lineno + ":" + event.colno : "";
    showRuntimeOverlay(event.error || event.message, file);
  });
  window.addEventListener("unhandledrejection", (event) => {
    showRuntimeOverlay(event.reason, "");
  });
}
const socket = new WebSocket(socketProtocol + "//" + location.host + "${APP_DEV_HMR_WS_PATH}");
socket.addEventListener("message", (event) => {
  const msg = JSON.parse(event.data);
  if (msg.type === "${HMR_MSG.Error}") {
    showOverlay(msg.errors);
    return;
  }
  if (msg.type === "${HMR_MSG.ClearError}") {
    hideOverlay();
    return;
  }
  if (msg.type === "${HMR_MSG.FullReload}") {
    hideOverlay();
    location.reload();
    return;
  }
  if (msg.type !== "${HMR_MSG.CssUpdate}") return;
  hideOverlay();
  const stamp = msg.timestamp || Date.now();
  const links = Array.from(document.querySelectorAll('link[rel="stylesheet"]'));
  let updated = false;
  for (const link of links) {
    const href = link.getAttribute("href");
    if (!href) continue;
    const current = new URL(href, location.href);
    const target = new URL(msg.href || current.pathname, location.href);
    if (msg.href && current.pathname !== target.pathname) continue;
    const next = new URL(current.href);
    next.searchParams.set("t", String(stamp));
    const replacement = link.cloneNode();
    replacement.href = next.href;
    replacement.onload = () => link.remove();
    replacement.onerror = () => location.reload();
    link.after(replacement);
    updated = true;
  }
  if (!updated) location.reload();
});
`;
