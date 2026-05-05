---
title: Dev Server
description: SSE event stream, Control API, and MCP server in the ZTS dev server
---

`zts --serve --bundle <entry>` starts a dev server that exposes **3 interfaces for external automation/observability** in addition to standard HTTP/HMR.

| Endpoint | Purpose | Compatible |
|---|---|---|
| `/sse/events` | Server-Sent Events stream — real-time build/watch events | rollipop |
| `/reset-cache` | Control API — invalidate cache externally | rollipop |
| `/mcp` | MCP (Model Context Protocol) JSON-RPC | Claude Code, MCP clients |

## Quick start

```bash
zts --serve --bundle src/index.tsx --port 12300
```

```bash
# Subscribe to SSE events
curl -N http://localhost:12300/sse/events

# Reset cache
curl -X POST http://localhost:12300/reset-cache

# Call MCP tool
curl -X POST http://localhost:12300/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## SSE event stream

### `GET /sse/events`

Response: `Content-Type: text/event-stream`, keep-alive connection.

Each event uses standard SSE format:
```
event: <type>
data: <json>

```

### Event types

| Type | When | Payload |
|---|---|---|
| `server_ready` | Server start | `{type, host, port}` |
| `watch_change` | File change detected | `{type, file}` |
| `bundle_build_started` | Build started | `{type, id}` |
| `bundle_build_done` | Build succeeded | `{type, id, totalModules, duration}` |
| `bundle_build_failed` | Build failed | `{type, id}` |
| `cache_reset` | Cache invalidated (manual/MCP) | `{type}` |

### Browser example

```ts
const es = new EventSource("http://localhost:12300/sse/events");
es.addEventListener("bundle_build_done", (e) => {
  const { duration, totalModules } = JSON.parse(e.data);
  console.log(`Built ${totalModules} modules in ${duration}ms`);
});
```

### Node example

```ts
const res = await fetch("http://localhost:12300/sse/events");
const reader = res.body!.getReader();
const decoder = new TextDecoder();
while (true) {
  const { value, done } = await reader.read();
  if (done) break;
  process.stdout.write(decoder.decode(value));
}
```

## Control API

### `ALL /reset-cache`

Invalidate the entire build cache. Next build is a full rebuild (all modules re-parsed/transformed).

Both GET and POST allowed.

Response:
```json
{"ok":true,"action":"reset_cache"}
```

When the cache is actually reset, a `cache_reset` event is published to SSE.

## MCP (Model Context Protocol)

LLM agents (Claude Code etc.) interact with the dev bundler via the standard MCP protocol. **JSON-RPC 2.0 over HTTP**.

### Registration (`.mcp.json`)

```json
{
  "mcpServers": {
    "zts": {
      "type": "http",
      "url": "http://localhost:12300/mcp"
    }
  }
}
```

Start the dev server first, then start the MCP client (Claude Code etc.).

### Supported methods

| Method | Description |
|---|---|
| `initialize` | Protocol handshake (version 2024-11-05) |
| `tools/list` | Returns tool list with JSON Schema |
| `tools/call` | Execute a tool |
| `notifications/initialized` | Client ready notification |

### Tools

#### `reset_cache`

Invalidate build cache. Same effect as Control API `/reset-cache`.

```json
{
  "jsonrpc": "2.0", "id": 1,
  "method": "tools/call",
  "params": { "name": "reset_cache", "arguments": {} }
}
```

#### `get_build_events`

Returns build events collected during the specified duration (ms) as a JSON array.

| Argument | Type | Default | Range |
|---|---|---|---|
| `duration` | number | 10000 | 1000~60000 (ms) |

```json
{
  "jsonrpc": "2.0", "id": 2,
  "method": "tools/call",
  "params": {
    "name": "get_build_events",
    "arguments": { "duration": 5000 }
  }
}
```

Response (`content[0].text` is a JSON string):
```json
[
  {"seq":42,"type":"watch_change","data":{"type":"watch_change","file":"src/App.tsx"}},
  {"seq":43,"type":"bundle_build_started","data":{"type":"bundle_build_started","id":"43"}},
  {"seq":44,"type":"bundle_build_done","data":{"type":"bundle_build_done","id":"43","totalModules":42,"duration":123.45}}
]
```

### LLM workflow example

```
1. get_build_events(2000) — capture current build state
2. (LLM modifies code)
3. get_build_events(10000) → wait for bundle_build_done or bundle_build_failed
4. If failed, read error message, fix → back to 2
5. If needed, reset_cache to clear cached state
```

## MCP error codes

| Code | Meaning |
|---|---|
| `-32600` | Invalid Request (not POST / body > 64KB / etc.) |
| `-32601` | Method not found |
| `-32602` | Unknown tool |
| `-32700` | Parse error (invalid JSON) |

## Limits

- **Body size**: MCP request body max 64KB. Returns HTTP 413 if exceeded.
- **HTTP method**: `/mcp` accepts POST only. GET etc. → 405.
- **Event buffer**: `get_build_events` reads from a 256-entry ring buffer. Older events are overwritten.
- **SSE concurrent connections**: 64. Additional connections rejected.

## `server` config (zts.config)

The same fields exposed via CLI `--port` / `--host` / `--open` can be set in the config file (Vite `server` compatible). CLI flags always take precedence.

```ts
// zts.config.ts
import { defineConfig } from "@zts/core";

export default defineConfig({
  server: {
    port: 12300,
    host: "0.0.0.0",      // boolean true also means 0.0.0.0 (Vite parity)
    strictPort: true,     // exit instead of trying the next port
    open: true,           // open the served URL in the browser after startup
  },
});
```

| Field | Type | Default | Description |
|---|---|---|---|
| `port` | `number` | `12300` | Listen port. CLI `--port` overrides. |
| `host` | `string \| boolean` | `"127.0.0.1"` | `true` = `0.0.0.0` (Vite parity). CLI `--host` overrides. |
| `strictPort` | `boolean` | `false` | If `true`, exit on port conflict instead of falling back to the next port. |
| `open` | `boolean` | `false` | Open the served URL in the browser after startup. CLI `--open` overrides. |

## Lazy sourcemap — `emitDiskSourcemap` + `WatchHandle`

When you host a dev server directly on top of `@zts/core`'s `watch()` handle, this moves the `.map` disk-write cost out of HMR latency.

```ts
import { watch } from "@zts/core";

const handle = watch({
  entryPoints: ["src/index.tsx"],
  outfile: "dist/bundle.js",
  bundle: true,
  sourcemap: true,
  emitDiskSourcemap: false,   // skip disk .map; keep in memory
  onRebuild(event) { /* ... */ },
});

// Lazily build /bundle.js.map on request
app.get("/bundle.js.map", (_req, res) => {
  const json = handle.getBundleSourceMap();
  if (!json) return res.sendStatus(404);
  res.type("application/json").send(json);
});

// Per-module HMR sourcemap (Metro `_processSourceMapRequest` pattern)
app.get("/hmr-map/:moduleId", (req, res) => {
  const json = handle.getHmrSourceMap(req.params.moduleId);
  if (!json) return res.sendStatus(404);
  res.type("application/json").send(json);
});
```

- `emitDiskSourcemap: true` (default): `.map` is automatically written to `output_filename + ".map"`.
- `emitDiskSourcemap: false`: skip disk I/O — use the lazy endpoint model above.
- `getBundleSourceMap()` / `getHmrSourceMap()` return `null` when sourcemap is off, before the first build, or after `stop()`.
- `getHmrSourceMap(moduleId)` returns `null` if `moduleId` was not part of the most recent rebuild.

## `onReady` / `onRebuild` events

The rich event payload delivered to `watch()` callbacks — consume the phase breakdown and HMR delta directly from a dev server integration.

```ts
watch({
  // ...
  onReady(event) {
    // event: WatchReadyEvent
    console.log(`ready: ${event.files} files / ${event.bytes} bytes`);
  },
  onRebuild(event) {
    // event: WatchRebuildEvent
    if (!event.success) {
      console.error("rebuild failed:", event.error);
      return;
    }
    for (const file of event.changed ?? []) console.log("changed:", file);
    for (const update of event.updates ?? []) {
      // update.id, update.code, update.map (per-module sourcemap V3 JSON)
      hmrSocket.send({ id: update.id, code: update.code, map: update.map });
    }
    const p = event.phaseDurations;
    if (p) console.log(`total=${p.total}ms graph=${p.graph}ms emit=${p.emit}ms`);
  },
});
```

Key fields on `WatchRebuildEvent`:

| Field | Type | Description |
|---|---|---|
| `success` | `boolean` | Whether the rebuild succeeded. |
| `error` | `string?` | The fatal diagnostic message on failure. |
| `changed` | `string[]?` | Absolute paths of files that triggered this rebuild. **It is `changed`, not `changedFiles`.** |
| `graphChanged` | `boolean?` | Whether the module graph topology changed. |
| `updates` | `Array<{ id, code, map? }>?` | HMR delta. `map` is the per-module standalone sourcemap V3 JSON (when sourcemap is enabled). |
| `bytes` | `number?` | Output byte count. |
| `reparsedModules` | `number?` | Modules that missed the cache and were re-parsed (not exposed for full builds). |
| `phaseDurations` | object | Per-phase ms — see table below. |

`phaseDurations` base phases (always measured):

| Field | Meaning |
|---|---|
| `detect` | Change detection (mtime scan). |
| `graph` | resolve + parse + semantic + finalize. |
| `link` | Scope hoisting + linker. |
| `shake` | Tree shaking. |
| `emit` | transform + codegen + emit. |
| `delta` | HMR delta extraction. |
| `total` | Sum of `detect` through `delta`. |

Sub-phases (only populated when `profile: ["..."]` / `ZTS_PROFILE=...` / `BUNGAE_HMR_PROFILE=1` is active; 0 otherwise):

`scan` / `parse` / `resolve` / `semantic` / `transform` / `codegen` / `metadata` / `graphBuild` / `graphWorker` / `graphDiscover` / `graphFinalize` / `emitPolyfill` / `emitRefresh` / `emitOutput` / `emitMetafile` / `emitCss` / `emitPrelude` / `emitModulePass` / `emitConcat` / `emitSourcemapFinalize`.

> Pre-2026-04-22 NAPI exposed `phaseDurations.parse` / `semantic`, which were actually `graph` / `link+shake` under legacy names and have been removed. Migrate to the new names (`graph` / `link` / `shake`).

## See also

- [Server-Sent Events (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
- [Model Context Protocol](https://modelcontextprotocol.io)
- [rollipop SSE/MCP](https://rollipop.dev/docs/features/sse) — compatible surface
