---
title: Dev Server
description: SSE event stream, Control API, and MCP server in the ZNTC dev server
---

`zntc --serve --bundle <entry>` starts a dev server that exposes **3 interfaces for external automation/observability** in addition to standard HTTP/HMR.

| Endpoint | Purpose | Compatible |
|---|---|---|
| `/sse/events` | Server-Sent Events stream — real-time build/watch events | rollipop |
| `/reset-cache` | Control API — invalidate cache externally | rollipop |
| `/mcp` | MCP (Model Context Protocol) JSON-RPC | Claude Code, MCP clients |

## Quick start

```bash
zntc --serve --bundle src/index.tsx --port 12300
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

## HMR — `import.meta.hot` API

`zntc --serve` pushes only changed modules to the client and re-runs them per module. Your code uses `import.meta.hot` to declare which modules are hot boundaries and what to do when an update arrives.

ZNTC's `import.meta.hot` is **Vite-compatible**. Existing Vite plugins / code mostly carries over.

### Basic usage

```ts
// src/store.ts
export const store = createStore();

if (import.meta.hot) {
  // Mark this module as a hot boundary
  import.meta.hot.accept((newModule) => {
    if (newModule) {
      // newModule.store is the new instance
      replaceStore(newModule.store);
    }
  });
}
```

The whole `import.meta.hot` block is removed automatically in **production builds** (only truthy in dev server).

### Accepting dependency changes

```ts
// Self-update
import.meta.hot.accept((newSelf) => { ... });

// A specific dep
import.meta.hot.accept('./logger', (newLogger) => { ... });

// Multiple deps at once
import.meta.hot.accept(['./a', './b'], ([newA, newB]) => { ... });
```

### Cleanup — `dispose`

Called right before the module is replaced. Use it to clean up timers / listeners / sockets:

```ts
const id = setInterval(tick, 1000);

if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    clearInterval(id);
  });
}
```

### Carrying state — `hot.data`

Whatever you put on the object that `dispose` receives is readable from the new module via `import.meta.hot.data` — i.e. state handed across module replacements.

```ts
let count = import.meta.hot?.data.count ?? 0;

if (import.meta.hot) {
  import.meta.hot.dispose((data) => {
    data.count = count;        // pass to the next module instance
  });
}
```

### Forcing a full reload — `invalidate`

When you receive an update but can't apply it safely:

```ts
if (import.meta.hot) {
  import.meta.hot.accept((newModule) => {
    if (!canSafelyApply(newModule)) {
      import.meta.hot.invalidate();   // full page reload
    }
  });
}
```

In browsers this calls `location.reload()`. In React Native, `DevSettings.reload()`.

### React Fast Refresh

If a `.tsx` / `.jsx` file's exports are **all React components**, ZNTC treats it as a hot boundary automatically — you don't need to write `import.meta.hot.accept` yourself. Component functions, `forwardRef`, `memo`, and `lazy` count as components.

```tsx
// Auto Fast Refresh — no explicit hot code needed
export function Button({ children }) {
  return <button>{children}</button>;
}
```

The auto boundary does NOT trigger (and a **full reload** happens) if:

- A component and a non-component value are **exported together** — e.g. `export const config = {...}; export function App() {}`
- The default export is an anonymous arrow (`export default () => <div />`) — no displayName
- A component reads module-scoped state for `useState` initial values (state can be lost)

Multiple component updates are batched into a single React refresh cycle with a 50 ms debounce.

### File-change detection — watcher

| OS | Mechanism |
|---|---|
| macOS | kqueue |
| Linux | inotify |
| Windows | ReadDirectoryChangesW |

In most environments OS events fire instantly. The following environments have unreliable OS events and may drop changes:

- Docker volume mounts (host → container)
- Network filesystems like NFS / SMB
- Windows WSL1 (WSL2 is fine)

ZNTC does not currently expose a polling-fallback flag. If changes don't propagate in those environments, force a browser reload manually. Polling fallback is planned for a future release.

### Debugging — when updates don't arrive

| Symptom | Suspect |
|---|---|
| Saving the file doesn't refresh the client | watcher (consider polling fallback above) or missing hot boundary (no full reload either) |
| Full reload happens repeatedly | Mixed exports, or no module along the dep chain calls `accept` |
| Component state resets every time | React Fast Refresh boundary broke — check for anonymous default export or mixed exports |
| Two instances coexist after update | Missing `dispose` — clean up timers/listeners |

Subscribe to `/sse/events` to see whether the watcher caught the change (`watch_change` event) and whether the build succeeded (`bundle_build_done`).

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
    "zntc": {
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

## Proxy — `--proxy`

The dev server can intercept backend API calls and forward them to a different origin. Use the CLI flag.

```bash
zntc dev . --proxy /api=http://localhost:8080
# multiple proxies — repeat the flag
zntc dev . --proxy /api=http://localhost:8080 --proxy /ws=http://localhost:9000
```

Requests whose path starts with the prefix are forwarded with the prefix stripped and appended to the target.

| Request | Forwarded to |
|---|---|
| `GET /api/users` (`--proxy /api=http://localhost:8080`) | `GET http://localhost:8080/users` |
| `GET /api/users?page=2` | `GET http://localhost:8080/users?page=2` |

### Limitations

Proxy currently supports only the simple *prefix → target* mapping. For any of the scenarios below, run a dedicated reverse proxy (nginx / Caddy / Node `http-proxy` in a separate process) in front of the dev server.

- **Request method / headers / body**: Under the Bun runtime, method, headers, and body are all dropped, so every request is effectively downgraded to `GET`. Under Node, method and headers are forwarded but the body is not. Either way, mutation APIs (POST / PUT / PATCH / DELETE) called through the proxy will not behave as intended.
- **Regex / functional path rewrite**: Only prefix-strip works. Transforms like `^/api/v1/(.*) → /v2/$1` are not supported.
- **WebSocket upgrade (`ws://`)**: HTTP upgrade requests are not intercepted. If you need a WebSocket target, an external reverse proxy is required.
- **Skipping self-signed cert verification for HTTPS targets**: No `secure: false` equivalent. Self-signed dev targets generally fail verification.
- **Host / Origin header rewriting**: The original `Host` header is forwarded as-is to the target. Virtual-host-based backends may reject the request.
- **Per-request bypass / custom middleware hook**: No hook to skip the proxy for some requests or to post-process the response.

> These options are planned for a future release. Until then we recommend an external reverse proxy.

## `server` config (zntc.config)

The same fields exposed via CLI `--port` / `--host` / `--open` can be set in the config file (Vite `server` compatible). CLI flags always take precedence.

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

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

## HTTPS — `--certfile` / `--keyfile`

Pass PEM-encoded cert / key files and the dev server listens on `https://localhost:12300`. HMR WebSockets are automatically upgraded to `wss://`.

```bash
zntc dev . --certfile ./certs/dev.pem --keyfile ./certs/dev-key.pem
```

### Generating a self-signed cert

For local development, [`mkcert`](https://github.com/FiloSottile/mkcert) is the easiest option — it sets up a local CA in your system trust store, so browsers don't show security warnings.

```bash
mkcert -install
mkcert localhost 127.0.0.1
# → localhost+1.pem (cert) / localhost+1-key.pem (key)

zntc dev . --certfile ./localhost+1.pem --keyfile ./localhost+1-key.pem
```

### Limitations

- TLS is only supported on the Node / Bun JS dev server (`zntc dev <root>`). `zntc serve` running as a standalone server does not support TLS — if you need a binary without Node installed, terminate TLS at an external reverse proxy (nginx / Caddy) in front of the dev server.
- Browser trust for self-signed certs depends on the OS / browser. Without `mkcert -install`, you may need workarounds like Chrome flags or `--ignore-certificate-errors`.

## Lazy sourcemap — `emitDiskSourcemap` + `WatchHandle`

When you host a dev server directly on top of `@zntc/core`'s `watch()` handle, this moves the `.map` disk-write cost out of HMR latency.

```ts
import { watch } from "@zntc/core";

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

Sub-phases (only populated when `profile: ["..."]` / `ZNTC_PROFILE=...` is active; 0 otherwise):

`scan` / `parse` / `resolve` / `semantic` / `transform` / `codegen` / `metadata` / `graphBuild` / `graphWorker` / `graphDiscover` / `graphFinalize` / `emitPolyfill` / `emitRefresh` / `emitOutput` / `emitMetafile` / `emitCss` / `emitPrelude` / `emitModulePass` / `emitConcat` / `emitSourcemapFinalize`.

> Pre-2026-04-22 NAPI exposed `phaseDurations.parse` / `semantic`, which were actually `graph` / `link+shake` under legacy names and have been removed. Migrate to the new names (`graph` / `link` / `shake`).

## See also

- [Server-Sent Events (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
- [Model Context Protocol](https://modelcontextprotocol.io)
- [rollipop SSE/MCP](https://rollipop.dev/docs/features/sse) — compatible surface
