// 브라우저 host — zntc 로 IIFE 빌드한 remote 의 컴포넌트를 표준
// @module-federation/runtime 으로 loadRemote 해서 react-dom 으로 렌더한다.
// host 가 react 를 shared singleton 으로 제공 → remote 의 useState 가 host 의
// 단일 react 인스턴스를 공유 (hooks 동작 조건). host.mjs(Node 검증)의 브라우저판.

import * as React from "react";
import { createRoot } from "react-dom/client";
import { init, loadRemote } from "@module-federation/runtime";

init({
  name: "host_web",
  remotes: [{ name: "remote_app", entry: "/remote/dist/index.js" }],
  shared: {
    react: {
      version: "19.0.0",
      lib: () => React,
      shareConfig: { singleton: true, requiredVersion: "^19" },
    },
  },
});

const { createElement: h, useState } = React;

function Shell({ children }: { children: React.ReactNode }) {
  return h(
    "div",
    { style: { fontFamily: "system-ui, sans-serif", padding: 24, maxWidth: 720, margin: "0 auto" } },
    h("h1", null, "ZNTC Module Federation"),
    h(
      "p",
      null,
      "host 가 zntc-IIFE remote(",
      h("code", null, "remote_app"),
      ")의 ",
      h("code", null, "Button"),
      " 을 표준 @module-federation/runtime 으로 loadRemote → react-dom 렌더. react 는 host 가 shared singleton 으로 제공.",
    ),
    children,
  );
}

function HostCounter() {
  const [n, setN] = useState(0);
  return h(
    "p",
    null,
    h("button", { onClick: () => setN(n + 1) }, `host 자체 카운터: ${n}`),
    " (remote 와 동일 react 인스턴스 — 양쪽 hooks 정상)",
  );
}

async function main() {
  const root = createRoot(document.getElementById("root")!);
  try {
    const mod = (await loadRemote("remote_app/Button")) as { default?: React.ComponentType } | React.ComponentType;
    const RemoteButton = ((mod as { default?: React.ComponentType }).default ?? mod) as React.ComponentType;
    root.render(h(Shell, null, h(HostCounter), h(RemoteButton)));
  } catch (err) {
    root.render(h(Shell, null, h("pre", { style: { color: "crimson" } }, String(err))));
  }
}

main();
