---
title: Module Federation
description: ZNTC Module Federation — expose and consume modules across independently built apps, interop with the standard runtime, and verify contracts at build time.
---

Module Federation lets separately built and deployed apps consume each
other's modules at runtime. The side that exports modules is a
**remote**; the side that consumes them is a **host**.

ZNTC does not reimplement the host runtime — it **targets the standard
`@module-federation/runtime` contract**. So a remote built with ZNTC can
be consumed as-is by a host built with webpack 5 / rspack, and a ZNTC
host can consume a standard remote (web).

## Configuration

Declare it in the `mf` block of `zntc.config` (`.ts`/`.js`/`.json`).

### Remote (exposes modules)

```json
{
  "mf": {
    "name": "remote_app",
    "exposes": { "./Button": "./src/Button.tsx" },
    "shared": { "react": { "singleton": true, "requiredVersion": "^19" } }
  }
}
```

- `name` — remote identifier (the host references it by this name).
- `exposes` — modules to expose: `{ publicPath: sourcePath }`.
- `shared` — dependencies that are not bundled but consumed as a single
  instance provided by the host. Required for libraries that must not be
  duplicated, like React.
  - `singleton` — allow only one instance.
  - `requiredVersion` — allowed version range (semver).
  - `strictVersion` — escalate a version mismatch to a **build failure**
    instead of a runtime fallback.
  - `shareScope` — the named share scope this dependency belongs to
    (default `"default"`). Used for gradual upgrades / domain isolation.

A remote is a container, not an app, so build it in core mode:

```sh
zntc --bundle src/index.ts --outdir dist --format=iife
```

Output: the container (remoteEntry) + `mf-manifest.json` +
content-hashed chunks.

### Host (consumes a remote)

```json
{
  "mf": {
    "name": "host_app",
    "remotes": { "remote_app": "remote_app@https://cdn.example.com/mf-manifest.json" },
    "shared": { "react": { "singleton": true, "requiredVersion": "^19" } }
  }
}
```

Host code can use both static and dynamic imports:

```ts
import Button from 'remote_app/Button';        // static
const m = await import('remote_app/Button');   // dynamic
```

`shareStrategy` (`"version-first"` default | `"loaded-first"`) controls
the shared negotiation order.

## How it works

- **Container / manifest** — the remote emits a container and a
  `mf-manifest.json` per the standard contract. The host consumes them
  via the standard runtime's `init`/`loadRemote` (no ZNTC runtime
  dependency).
- **Shared dependencies** — packages declared in `shared` are not
  bundled; they use the single instance the host registers. Host and
  remote therefore share the same React instance and hooks work.
  Multiple named scopes can be used simultaneously.
- **Build-time contract verification** — ZNTC's differentiator. The host
  build reads the consumed remote's `mf-manifest.json` and catches
  contract violations **at build time, not at runtime**:
  - If a `remote/<subpath>` the host imports is missing from the
    consumed remote's manifest, the host build fails.
  - If a shared dependency's version/singleton does not match the host's
    requirement, a warning (or a build failure under `strictVersion`).
  - If manifest integrity (digest/signature) is tampered or stale, the
    build fails.
- **Runtime guard** — cases that cannot be verified at build time
  (unreachable remote, runtime-registered remotes) degrade gracefully at
  runtime so the shell survives.
- **CSS** — when an exposed module imports CSS, the CSS assets are
  recorded in the manifest so the standard runtime preloads the
  stylesheet alongside.

## Limitations

- **Web only** — React Native is not supported yet.
- **Runtime-registered remotes** — remotes that host code registers **at
  runtime** via the standard runtime's `registerRemotes()` /
  `init({ remotes })` do not exist at build time, so their contract
  cannot be build-verified. They still work (delegated to the standard
  runtime) and the runtime guard covers that blind spot. Build
  verification targets remotes identified via config `remotes` and the
  static/dynamic imports scanned at build time.
- **Remote manifest fetch** — build-time contract verification targets
  locally resolvable manifests. A manifest only reachable over the
  network is not verified at build time and is left to the runtime
  guard.
- **No type generation** — ZNTC does not auto-generate `.d.ts` for a
  remote. Consumers use their own type declarations (ZNTC's
  differentiator is build-time contract verification, not type-hint
  downloading).

For a minimal working example, see
[`examples/module-federation`](https://github.com/ohah/zntc/tree/main/examples/module-federation)
— a ZNTC remote consumed by a standard `@module-federation/runtime`
host, verifying a single shared React instance.
