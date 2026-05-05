import { afterAll, beforeAll, describe, expect, test } from "bun:test";

import {
  createBaseMiddleware,
  createDevHttpServer,
  type DevHttpServerHandle,
} from "./http-server.ts";
import { buildRnDevServerOptions } from "./options.ts";
import type { PlatformStateRegistry } from "./platform-state.ts";

const BUNDLE = {
  entry: "/proj/src/index.ts",
  projectRoot: "/proj",
  rnPlatform: "ios" as const,
  dev: true,
};

const noopPlatforms: PlatformStateRegistry = {
  platforms: new Map(),
  getOrCreate: () => {
    throw new Error("not used");
  },
  async stopAll() {},
};

let handle: DevHttpServerHandle;
const recorded: Array<[string, unknown?]> = [];

beforeAll(async () => {
  handle = await createDevHttpServer(buildRnDevServerOptions({ bundle: BUNDLE, port: 0 }), {
    broadcast: (m, p) => recorded.push([m, p]),
    platforms: noopPlatforms,
  });
});

afterAll(async () => {
  await handle.stop();
});

function url(path: string): string {
  const addr = handle.server.address();
  if (typeof addr === "string" || !addr) throw new Error("no addr");
  return `http://localhost:${addr.port}${path}`;
}

describe("createDevHttpServer — index page (`/` `/index.html`)", () => {
  test("GET / → 200 HTML + bundle/map/HMR link 포함", async () => {
    const res = await fetch(url("/"));
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("text/html; charset=utf-8");
    const body = await res.text();
    expect(body).toContain("ZTS RN Dev Server");
    expect(body).toContain("/index.bundle?platform=ios&dev=true");
    expect(body).toContain("/index.bundle?platform=android&dev=true");
    expect(body).toContain("/index.bundle.map?platform=ios");
    // ws:// link 의 port 가 응답에 반영 (port=0 으로 listen 시 actual port 가 다름이라
    // body 에는 options.port=0 그대로 — caller-set port. dev 시 8081 일 때 정상).
  });

  test("GET /index.html — alias 동작", async () => {
    const res = await fetch(url("/index.html"));
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("text/html; charset=utf-8");
  });
});

describe("createDevHttpServer — base routes", () => {
  test("GET /status → 200 packager-status:running + project-root header", async () => {
    const res = await fetch(url("/status"));
    expect(res.status).toBe(200);
    expect(res.headers.get("X-React-Native-Project-Root")).toBe("/proj");
    expect(await res.text()).toBe("packager-status:running");
  });

  test("GET /status.txt — Metro alias", async () => {
    const res = await fetch(url("/status.txt"));
    expect(res.status).toBe(200);
  });

  test("GET /reload → broadcast('reload') + 200 OK", async () => {
    recorded.length = 0;
    const res = await fetch(url("/reload"));
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("OK");
    expect(recorded).toEqual([["reload", undefined]]);
  });

  test("GET /devmenu → broadcast('devMenu') + 200 OK", async () => {
    recorded.length = 0;
    const res = await fetch(url("/devmenu"));
    expect(res.status).toBe(200);
    expect(recorded).toEqual([["devMenu", undefined]]);
  });

  test("POST /open-url with valid JSON body → 200", async () => {
    const res = await fetch(url("/open-url"), {
      method: "POST",
      body: JSON.stringify({ url: "https://example.test" }),
      headers: { "Content-Type": "application/json" },
    });
    // 실제 spawn 은 OS 의존이라 200/500 둘 다 허용. 200 이면 spawn 성공, 500 이면 실패.
    expect([200, 500]).toContain(res.status);
  });

  test("POST /open-url with empty body → 400", async () => {
    const res = await fetch(url("/open-url"), {
      method: "POST",
      body: "{}",
      headers: { "Content-Type": "application/json" },
    });
    expect(res.status).toBe(400);
  });

  test("GET /open-url (POST 만 허용) → 404", async () => {
    const res = await fetch(url("/open-url"));
    expect(res.status).toBe(404);
  });

  test("미매치 path → 404 Not Found", async () => {
    const res = await fetch(url("/__nope"));
    expect(res.status).toBe(404);
    expect(await res.text()).toBe("Not Found");
  });
});

describe("createBaseMiddleware — rewriteRequestUrl 호출", () => {
  test("rewriteRequestUrl 결과로 매칭", () => {
    const opts = buildRnDevServerOptions({
      bundle: BUNDLE,
      rewriteRequestUrl: () => "/status",
    });
    const mw = createBaseMiddleware(opts, { broadcast: () => {}, platforms: noopPlatforms });
    let body: string | undefined;
    let code: number | undefined;
    const headers: Record<string, unknown> = {};
    mw(
      { url: "/__weird", headers: { host: "x:1" } } as never,
      {
        setHeader: (k: string, v: string) => {
          headers[k] = v;
        },
        writeHead: (c: number) => {
          code = c;
        },
        end: (b: string) => {
          body = b;
        },
      } as never,
      () => {},
    );
    expect(code).toBe(200);
    expect(body).toBe("packager-status:running");
  });
});

describe("createDevHttpServer — chain error/terminal 경로", () => {
  test("enhanceMiddleware next(err) → 500 Internal Server Error", async () => {
    const opts = buildRnDevServerOptions({
      bundle: BUNDLE,
      port: 0,
      enhanceMiddleware: () => (_req, _res, next) => next(new Error("boom")),
    });
    const h = await createDevHttpServer(opts, { broadcast: () => {}, platforms: noopPlatforms });
    try {
      const addr = h.server.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      const res = await fetch(`http://localhost:${port}/anything`);
      expect(res.status).toBe(500);
      expect(await res.text()).toContain("boom");
    } finally {
      await h.stop();
    }
  });

  test("enhanceMiddleware 가 res.end() 후 next() — 추가 응답 안 보냄", async () => {
    const opts = buildRnDevServerOptions({
      bundle: BUNDLE,
      port: 0,
      enhanceMiddleware: () => (_req, res, next) => {
        res.writeHead(204);
        res.end();
        next();
      },
    });
    const h = await createDevHttpServer(opts, { broadcast: () => {}, platforms: noopPlatforms });
    try {
      const addr = h.server.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      const res = await fetch(`http://localhost:${port}/x`);
      expect(res.status).toBe(204);
      expect(await res.text()).toBe("");
    } finally {
      await h.stop();
    }
  });
});

describe("createDevHttpServer — enhanceMiddleware", () => {
  test("enhanceMiddleware 가 chain 의 첫 layer 가 됨", async () => {
    const opts = buildRnDevServerOptions({
      bundle: BUNDLE,
      port: 0,
      enhanceMiddleware: (base) => (req, res, next) => {
        if (req.url === "/__custom") {
          res.writeHead(200, { "Content-Type": "text/plain" });
          res.end("custom");
          return;
        }
        base(req, res, next);
      },
    });
    const h = await createDevHttpServer(opts, { broadcast: () => {}, platforms: noopPlatforms });
    try {
      const addr = h.server.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      const res = await fetch(`http://localhost:${port}/__custom`);
      expect(await res.text()).toBe("custom");
      const status = await fetch(`http://localhost:${port}/status`);
      expect(status.status).toBe(200);
    } finally {
      await h.stop();
    }
  });

  test("enhanceMiddleware 미지정 시 base 만", async () => {
    const opts = buildRnDevServerOptions({ bundle: BUNDLE, port: 0 });
    const h = await createDevHttpServer(opts, { broadcast: () => {}, platforms: noopPlatforms });
    try {
      const addr = h.server.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      const res = await fetch(`http://localhost:${port}/status`);
      expect(res.status).toBe(200);
    } finally {
      await h.stop();
    }
  });

  test("invalid host → listen error reject", async () => {
    await expect(
      createDevHttpServer(
        buildRnDevServerOptions({ bundle: BUNDLE, port: 0, host: "256.256.256.256" }),
        { broadcast: () => {}, platforms: noopPlatforms },
      ),
    ).rejects.toThrow();
  });
});

describe("attachWebSocketEndpoints — chain ordering (Finding #4)", () => {
  test("listener: hmrBridge `/hot` 우선 → cli endpoints → dev endpoints → unmatched destroy", async () => {
    const recorded: string[] = [];
    const opts = buildRnDevServerOptions({ bundle: BUNDLE, port: 0 });
    const fakeHmr = {
      adapter: {} as never,
      callbacks: {},
      path: "/hot",
      acceptUpgrade: () => recorded.push("hmr:/hot"),
    };
    const fakeCli = {
      websocketEndpoints: {
        "/message": {
          handleUpgrade: () => recorded.push("cli:/message"),
          emit: () => {},
        },
      },
      broadcast: () => {},
    };
    const fakeDev = {
      middleware: ((_req: never, _res: never, _next: never) => {}) as never,
      websocketEndpoints: {
        "/inspector": {
          handleUpgrade: () => recorded.push("dev:/inspector"),
          emit: () => {},
        },
      },
    };
    const h = await createDevHttpServer(opts, {
      broadcast: () => {},
      platforms: noopPlatforms,
      hmrBridge: fakeHmr,
      cliServerApi: fakeCli,
      devMiddleware: fakeDev as never,
    });

    try {
      // 단일 'upgrade' listener — server.listeners('upgrade')[0] 가져와 직접 호출.
      const listeners = h.server.listeners("upgrade");
      expect(listeners).toHaveLength(1);
      const upgradeListener = listeners[0]! as (req: unknown, sock: unknown, head: unknown) => void;

      const fakeSocket = { destroy: () => recorded.push("destroyed") };
      const head = Buffer.alloc(0);

      upgradeListener({ url: "/hot", headers: { host: "x:8081" } }, fakeSocket, head);
      upgradeListener({ url: "/message", headers: { host: "x:8081" } }, fakeSocket, head);
      upgradeListener({ url: "/inspector", headers: { host: "x:8081" } }, fakeSocket, head);
      upgradeListener({ url: "/__nope__", headers: { host: "x:8081" } }, fakeSocket, head);

      expect(recorded).toEqual(["hmr:/hot", "cli:/message", "dev:/inspector", "destroyed"]);
    } finally {
      await h.stop();
    }
  });

  test("hmrBridge 만 — cli/dev 미설치 시 hmr 만 chain", async () => {
    const recorded: string[] = [];
    const opts = buildRnDevServerOptions({ bundle: BUNDLE, port: 0 });
    const fakeHmr = {
      adapter: {} as never,
      callbacks: {},
      path: "/hot",
      acceptUpgrade: () => recorded.push("hmr"),
    };
    const h = await createDevHttpServer(opts, {
      broadcast: () => {},
      platforms: noopPlatforms,
      hmrBridge: fakeHmr,
    });
    try {
      const listeners = h.server.listeners("upgrade");
      expect(listeners).toHaveLength(1);
      const fn = listeners[0]! as (req: unknown, s: unknown, h: unknown) => void;
      const sock = { destroy: () => recorded.push("destroyed") };
      fn({ url: "/hot", headers: {} }, sock, Buffer.alloc(0));
      fn({ url: "/other", headers: {} }, sock, Buffer.alloc(0));
      expect(recorded).toEqual(["hmr", "destroyed"]);
    } finally {
      await h.stop();
    }
  });

  test("아무 deps 없으면 'upgrade' listener 미등록 (Node default 동작)", async () => {
    const opts = buildRnDevServerOptions({ bundle: BUNDLE, port: 0 });
    const h = await createDevHttpServer(opts, {
      broadcast: () => {},
      platforms: noopPlatforms,
    });
    try {
      expect(h.server.listenerCount("upgrade")).toBe(0);
    } finally {
      await h.stop();
    }
  });
});

describe("createDevHttpServer — listener cleanup (Finding #3)", () => {
  test("stop() 후 server 의 'request' / 'upgrade' listener 가 모두 정리됨", async () => {
    const opts = buildRnDevServerOptions({ bundle: BUNDLE, port: 0 });
    const fakeHmr = {
      adapter: {} as never,
      callbacks: {},
      path: "/hot",
      acceptUpgrade: () => {},
    };
    const fakeCli = {
      websocketEndpoints: {
        "/message": { handleUpgrade: () => {}, emit: () => {} },
      },
      broadcast: () => {},
    };
    const h = await createDevHttpServer(opts, {
      broadcast: () => {},
      platforms: noopPlatforms,
      hmrBridge: fakeHmr,
      cliServerApi: fakeCli,
    });
    // listen 후 'request' 1 + 'upgrade' 1 (hmr/cli/dev 중 하나라도 있으면).
    expect(h.server.listenerCount("request")).toBe(1);
    expect(h.server.listenerCount("upgrade")).toBe(1);
    await h.stop();
    // 현재 createDevHttpServer.stop() 은 server.close() 만 호출 — listener 명시 제거
    // 안 함. server.close() 는 listener 자동 제거 안 함 (Node API spec).
    // 이 expect 는 fix 전 fail.
    expect(h.server.listenerCount("request")).toBe(0);
    expect(h.server.listenerCount("upgrade")).toBe(0);
  });
});
