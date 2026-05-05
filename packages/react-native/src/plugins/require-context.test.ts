import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createRequireContextPlugin } from "./require-context.ts";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "zts-rn-rc-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

interface OnResolveContextHandler {
  (args: { dir: string; recursive: boolean; filter?: string; flags?: string; importer: string }): {
    context: string[];
  };
}

function captureHandler(): OnResolveContextHandler {
  const plugin = createRequireContextPlugin();
  let captured: OnResolveContextHandler | null = null;
  const fakeBuild = {
    onResolveContext(_filter: { filter: RegExp }, handler: OnResolveContextHandler) {
      captured = handler;
    },
    onResolve() {},
    onLoad() {},
    onTransform() {},
  };
  // ZtsPlugin.setup 시그니처 호환 (Build 의 onResolveContext 만 사용).
  plugin.setup(fakeBuild as never);
  if (!captured) throw new Error("handler not registered");
  return captured;
}

describe("createRequireContextPlugin", () => {
  test("디렉토리 없음 — `{ context: [] }`", () => {
    const handler = captureHandler();
    const result = handler({
      dir: "./missing",
      recursive: false,
      importer: join(dir, "index.ts"),
    });
    expect(result).toEqual({ context: [] });
  });

  test("non-recursive — 1단계 파일만, default filter `^\\./.*$`", () => {
    mkdirSync(join(dir, "ctx"), { recursive: true });
    writeFileSync(join(dir, "ctx", "a.ts"), "");
    writeFileSync(join(dir, "ctx", "b.ts"), "");
    mkdirSync(join(dir, "ctx", "nested"));
    writeFileSync(join(dir, "ctx", "nested", "deep.ts"), "");

    const handler = captureHandler();
    const result = handler({
      dir: "./ctx",
      recursive: false,
      importer: join(dir, "index.ts"),
    });
    expect(result.context.sort()).toEqual(["./a.ts", "./b.ts"]);
  });

  test("recursive — 모든 sub-tree 파일, slash 정규화", () => {
    mkdirSync(join(dir, "ctx", "sub"), { recursive: true });
    writeFileSync(join(dir, "ctx", "a.ts"), "");
    writeFileSync(join(dir, "ctx", "sub", "deep.ts"), "");

    const handler = captureHandler();
    const result = handler({
      dir: "./ctx",
      recursive: true,
      importer: join(dir, "index.ts"),
    });
    expect(result.context.sort()).toEqual(["./a.ts", "./sub/deep.ts"]);
  });

  test("custom filter regex 적용", () => {
    mkdirSync(join(dir, "ctx"), { recursive: true });
    writeFileSync(join(dir, "ctx", "a.ts"), "");
    writeFileSync(join(dir, "ctx", "b.js"), "");
    writeFileSync(join(dir, "ctx", "c.png"), "");

    const handler = captureHandler();
    const result = handler({
      dir: "./ctx",
      recursive: false,
      filter: "\\.(ts|js)$",
      importer: join(dir, "index.ts"),
    });
    expect(result.context.sort()).toEqual(["./a.ts", "./b.js"]);
  });

  test("filter regex flags 적용", () => {
    mkdirSync(join(dir, "ctx"), { recursive: true });
    writeFileSync(join(dir, "ctx", "Foo.ts"), "");
    writeFileSync(join(dir, "ctx", "BAR.ts"), "");

    const handler = captureHandler();
    const result = handler({
      dir: "./ctx",
      recursive: false,
      filter: "foo\\.ts$",
      flags: "i",
      importer: join(dir, "index.ts"),
    });
    expect(result.context).toEqual(["./Foo.ts"]);
  });

  test("결정적 순서 (사전식 sort)", () => {
    mkdirSync(join(dir, "ctx"), { recursive: true });
    for (const name of ["c.ts", "a.ts", "b.ts"]) {
      writeFileSync(join(dir, "ctx", name), "");
    }
    const handler = captureHandler();
    const result = handler({
      dir: "./ctx",
      recursive: false,
      importer: join(dir, "index.ts"),
    });
    expect(result.context).toEqual(["./a.ts", "./b.ts", "./c.ts"]);
  });

  test("filter 미지정 시 default `^\\./.*$` — 모든 파일 매칭", () => {
    mkdirSync(join(dir, "ctx"), { recursive: true });
    writeFileSync(join(dir, "ctx", "a.txt"), "");
    writeFileSync(join(dir, "ctx", "b.png"), "");
    const handler = captureHandler();
    const result = handler({
      dir: "./ctx",
      recursive: false,
      importer: join(dir, "index.ts"),
    });
    expect(result.context.sort()).toEqual(["./a.txt", "./b.png"]);
  });
});
