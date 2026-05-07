// GET /index.bundle, /index.bundle.js — RN runtime 의 첫 요청. multipart/mixed
// (RN 의 progress bar 호환) 또는 plain application/javascript. sourceMappingURL
// + sourceURL 주석 추가 (Hermes source map matching 위해 jscSafeUrl).

import type { IncomingMessage, ServerResponse } from 'node:http';

import * as jscSafeUrl from 'jsc-safe-url';

import { sendText } from '../http-utils.ts';
import { getCachedSourceMap, type PlatformStateRegistry, waitForBuild } from '../platform-state.ts';
import { postProcessSourceMap } from '../sourcemap.ts';
import { resolvePlatform } from './_shared.ts';

const HMR_MAP_PREFIX = '/__zntc_hmr_map/';
const MULTIPART_BOUNDARY = '3beqjf3apnqeu3h5jqorms4i';
const CRLF = '\r\n';
const METRO_NO_STORE_HEADERS = {
  'Surrogate-Control': 'no-store',
  'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate',
  Pragma: 'no-cache',
  Expires: '0',
};

export function isBundleRoute(pathname: string): boolean {
  return pathname.endsWith('.bundle') || pathname.endsWith('.bundle.js');
}

export function isMapRoute(pathname: string): boolean {
  return pathname.endsWith('.map') || pathname.endsWith('.bundle.map');
}

export function isHmrMapRoute(pathname: string): boolean {
  return pathname.startsWith(HMR_MAP_PREFIX);
}

export async function handleBundleRequest(
  req: IncomingMessage,
  res: ServerResponse,
  url: URL,
  registry: PlatformStateRegistry,
  defaultPlatform: 'ios' | 'android',
  projectRoot: string,
  port: number,
): Promise<void> {
  const state = resolvePlatform(url, registry, defaultPlatform);
  if (state.bundle === null && state.buildError === null) {
    await waitForBuild(state);
  }

  if (state.buildError) {
    sendText(
      res,
      200,
      `throw new Error(${JSON.stringify(state.buildError)});`,
      'application/javascript',
    );
    return;
  }
  if (!state.bundle) {
    sendText(res, 503, 'Bundle not ready yet. Build may have failed - check server logs.');
    return;
  }

  // sourceURL = jscSafeUrl 형태 (Hermes 가 source map 매칭 시 jscSafe URL 기대).
  const host = req.headers.host || `localhost:${port}`;
  const fullUrl = `http://${host}${url.pathname}${url.search}${url.hash || ''}`;
  const bundleUrl = jscSafeUrl.toJscSafeUrl(fullUrl);
  const mapPathname = url.pathname.replace(/\.bundle(\.js)?$/, '.map');
  const mapUrl = `http://${host}${mapPathname}${url.search}`;
  const bundle = `${state.bundle}\n//# sourceMappingURL=${mapUrl}\n//# sourceURL=${bundleUrl}`;

  if (req.headers.accept === 'multipart/mixed') {
    res.writeHead(200, {
      'Content-Type': `multipart/mixed; boundary="${MULTIPART_BOUNDARY}"`,
      ...METRO_NO_STORE_HEADERS,
      'X-React-Native-Project-Root': projectRoot,
    });
    res.write('If you are seeing this, your client does not support multipart response');
    res.write(
      `${CRLF}--${MULTIPART_BOUNDARY}${CRLF}` +
        `Content-Type: application/json${CRLF}${CRLF}` +
        JSON.stringify({ done: state.fileCount, total: state.fileCount }),
    );
    const bundleBytes = Buffer.byteLength(bundle);
    const revisionId = `${Date.now()}-${Math.random().toString(36).substring(7)}`;
    res.end(
      `${CRLF}--${MULTIPART_BOUNDARY}${CRLF}` +
        `X-Metro-Files-Changed-Count: ${state.fileCount}${CRLF}` +
        `X-Metro-Delta-ID: ${revisionId}${CRLF}` +
        `Content-Type: application/javascript; charset=UTF-8${CRLF}` +
        `Content-Length: ${bundleBytes}${CRLF}` +
        `Last-Modified: ${new Date().toUTCString()}${CRLF}${CRLF}` +
        bundle +
        `${CRLF}--${MULTIPART_BOUNDARY}--${CRLF}`,
    );
    return;
  }

  res.writeHead(200, {
    'X-Content-Type-Options': 'nosniff',
    ...METRO_NO_STORE_HEADERS,
    'Content-Type': 'application/javascript; charset=UTF-8',
    'Content-Length': Buffer.byteLength(bundle),
    'X-React-Native-Project-Root': projectRoot,
    'Content-Location': bundleUrl,
  });
  res.end(bundle);
}

export function handleMapRequest(
  _req: IncomingMessage,
  res: ServerResponse,
  url: URL,
  registry: PlatformStateRegistry,
  defaultPlatform: 'ios' | 'android',
): void {
  const state = resolvePlatform(url, registry, defaultPlatform);
  const json = getCachedSourceMap(state);
  if (!json) {
    sendText(res, 404, 'Source map not available');
    return;
  }
  res.writeHead(200, {
    'X-Content-Type-Options': 'nosniff',
    ...METRO_NO_STORE_HEADERS,
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(json),
    'Access-Control-Allow-Origin': 'devtools://devtools',
  });
  res.end(json);
}

export function handleHmrMapRequest(
  _req: IncomingMessage,
  res: ServerResponse,
  url: URL,
  registry: PlatformStateRegistry,
  defaultPlatform: 'ios' | 'android',
): void {
  const state = resolvePlatform(url, registry, defaultPlatform);
  const moduleId = decodeURIComponent(url.pathname.slice(HMR_MAP_PREFIX.length));
  const rawJson = state.handle.getHmrSourceMap(moduleId);
  if (!rawJson) {
    sendText(res, 404, 'HMR source map not found');
    return;
  }
  const json = postProcessSourceMap(rawJson);
  res.writeHead(200, {
    'X-Content-Type-Options': 'nosniff',
    ...METRO_NO_STORE_HEADERS,
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(json),
    'Access-Control-Allow-Origin': 'devtools://devtools',
  });
  res.end(json);
}
