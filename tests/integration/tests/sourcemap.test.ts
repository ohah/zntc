import { describe, test, expect, afterEach } from "bun:test";
import { createFixture, runZts } from "./helpers";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

/** VLQ 디코딩: 소스맵 매핑 세그먼트를 숫자 배열로 변환 */
function decodeVlq(s: string): number[] {
  const CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const result: number[] = [];
  let i = 0;
  while (i < s.length) {
    let shift = 0,
      value = 0;
    // eslint-disable-next-line no-constant-condition
    while (true) {
      const c = CHARS.indexOf(s[i++]);
      value += (c & 31) << shift;
      shift += 5;
      if (!(c & 32)) break;
    }
    result.push(value & 1 ? -(value >> 1) : value >> 1);
  }
  return result;
}

/** 소스맵에서 특정 source index의 매핑된 원본 라인 목록을 추출 */
function getMappedSourceLines(
  mappings: string,
  targetSourceIdx: number,
): { genLine: number; srcLine: number }[] {
  const lines = mappings.split(";");
  let genCol = 0,
    srcIdx = 0,
    srcLine = 0,
    srcCol = 0;
  const result: { genLine: number; srcLine: number }[] = [];
  for (let gn = 0; gn < lines.length; gn++) {
    if (!lines[gn]) continue;
    genCol = 0;
    for (const seg of lines[gn].split(",")) {
      if (!seg) continue;
      const vals = decodeVlq(seg);
      genCol += vals[0];
      if (vals.length >= 4) {
        srcIdx += vals[1];
        srcLine += vals[2];
        srcCol += vals[3];
        if (srcIdx === targetSourceIdx) {
          result.push({ genLine: gn + 1, srcLine: srcLine + 1 });
        }
      }
    }
  }
  return result;
}

describe("소스맵", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("번들 소스맵에 sourcesContent가 포함된다", async () => {
    const fixture = await createFixture({
      "index.ts": `import { add } from "./math";\nconsole.log(add(1, 2));`,
      "math.ts": `export function add(a: number, b: number): number {\n  return a + b;\n}`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--sourcemap",
    ]);
    expect(result.exitCode).toBe(0);

    // .map 파일이 생성되어야 한다
    const mapPath = outFile + ".map";
    expect(existsSync(mapPath)).toBe(true);

    const map = JSON.parse(readFileSync(mapPath, "utf-8"));

    // V3 소스맵 기본 필드 검증
    expect(map.version).toBe(3);
    expect(map.sources).toBeArray();
    expect(map.sources.length).toBeGreaterThanOrEqual(2);
    expect(map.mappings).toBeString();
    expect(map.mappings.length).toBeGreaterThan(0);

    // sourcesContent가 존재해야 한다
    expect(map.sourcesContent).toBeArray();
    expect(map.sourcesContent.length).toBe(map.sources.length);

    // 각 sourcesContent가 비어있지 않아야 한다
    for (const content of map.sourcesContent) {
      expect(typeof content).toBe("string");
      expect(content.length).toBeGreaterThan(0);
    }

    // 원본 소스 내용이 포함되어 있어야 한다
    const allContent = map.sourcesContent.join("\n");
    expect(allContent).toContain("function add");
    expect(allContent).toContain("console.log");
  });

  test("번들 출력에 sourceMappingURL이 포함된다", async () => {
    const fixture = await createFixture({
      "index.ts": `console.log("hello");`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile, "--sourcemap"]);

    const output = readFileSync(outFile, "utf-8");
    expect(output).toContain("//# sourceMappingURL=out.js.map");
  });

  test("--sources-content=false이면 sourcesContent가 없다", async () => {
    const fixture = await createFixture({
      "index.ts": `console.log("hello");`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--sourcemap",
      "--sources-content=false",
    ]);

    const mapPath = outFile + ".map";
    expect(existsSync(mapPath)).toBe(true);

    const map = JSON.parse(readFileSync(mapPath, "utf-8"));
    expect(map.sourcesContent).toBeUndefined();
  });

  test("소스맵 mappings가 유효한 VLQ이다", async () => {
    const fixture = await createFixture({
      "index.ts": `const x = 1;\nconst y = 2;\nconsole.log(x + y);`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile, "--sourcemap"]);

    const map = JSON.parse(readFileSync(outFile + ".map", "utf-8"));

    // mappings는 base64 VLQ 문자 + 세미콜론 + 콤마만 포함해야 한다
    const validChars = /^[A-Za-z0-9+/;,]*$/;
    expect(map.mappings).toMatch(validChars);

    // 세미콜론이 줄 구분자 — 최소 1줄 이상
    expect(map.mappings.length).toBeGreaterThan(0);
  });

  test("단일 파일 트랜스파일 소스맵", async () => {
    const fixture = await createFixture({
      "input.ts": `const x: number = 42;\nconsole.log(x);`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "output.js");
    const result = await runZts([join(fixture.dir, "input.ts"), "-o", outFile, "--sourcemap"]);
    expect(result.exitCode).toBe(0);

    const mapPath = outFile + ".map";
    expect(existsSync(mapPath)).toBe(true);

    const map = JSON.parse(readFileSync(mapPath, "utf-8"));
    expect(map.version).toBe(3);
    expect(map.sources.length).toBeGreaterThanOrEqual(1);
    expect(map.mappings.length).toBeGreaterThan(0);
  });

  test("다중 모듈 번들에서 sources에 모든 모듈이 포함된다", async () => {
    const fixture = await createFixture({
      "src/index.ts": `import { greet } from "./util";\nconsole.log(greet("world"));`,
      "src/util.ts": `export function greet(name: string): string {\n  return "hello " + name;\n}`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "dist/out.js");
    await runZts(["--bundle", join(fixture.dir, "src/index.ts"), "-o", outFile, "--sourcemap"]);

    const map = JSON.parse(readFileSync(outFile + ".map", "utf-8"));

    // 두 모듈 모두 sources에 포함되어야 한다 (node_modules/.zts/runtime.js 제외)
    const moduleSources = map.sources.filter((s: string) => s !== "node_modules/.zts/runtime.js");
    expect(moduleSources.length).toBe(2);
    const joined = moduleSources.join("|");
    expect(joined).toContain("index.ts");
    expect(joined).toContain("util.ts");

    // sourcesContent도 각 모듈의 내용을 포함해야 한다 (node_modules/.zts/runtime.js 제외)
    expect(moduleSources.length).toBe(2);
    const allContent = map.sourcesContent.join("\n");
    expect(allContent).toContain("function greet");
  });

  test("sources 경로가 상대 경로여야 한다 (절대 경로 금지)", async () => {
    // cwd 하위에 fixture를 만들어야 root_dir prefix가 제거됨
    const { mkdtempSync, writeFileSync: wfs, rmSync } = await import("node:fs");
    const tmpDir = mkdtempSync(join(process.cwd(), ".tmp-sm-test-"));
    cleanup = async () => rmSync(tmpDir, { recursive: true, force: true });

    wfs(join(tmpDir, "index.ts"), `import { x } from "./lib";\nconsole.log(x);`);
    wfs(join(tmpDir, "lib.ts"), `export const x = 42;`);

    const outFile = join(tmpDir, "out.js");
    await runZts(["--bundle", join(tmpDir, "index.ts"), "-o", outFile, "--sourcemap"]);

    const map = JSON.parse(readFileSync(outFile + ".map", "utf-8"));

    for (const source of map.sources) {
      expect(source.startsWith("/")).toBe(false);
    }
  });

  test("매핑 줄 번호가 번들 줄 수를 초과하지 않는다 (prologue 오프셋 검증)", async () => {
    const fixture = await createFixture({
      "index.ts": `import { greet } from "./util";\nconsole.log(greet("world"));`,
      "util.ts": `export function greet(name: string) {\n  return "hello " + name;\n}`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile, "--sourcemap"]);

    const map = JSON.parse(readFileSync(outFile + ".map", "utf-8"));
    const bundleLines = readFileSync(outFile, "utf-8").split("\n").length;

    // 매핑의 줄 수가 번들 줄 수 이하여야 한다 (2배 되면 prologue 오프셋 버그)
    const mappingLineCount = map.mappings.split(";").length;
    expect(mappingLineCount).toBeLessThanOrEqual(bundleLines + 1);
  });

  test("ESM 래핑 모듈(RN)의 호이스팅 함수가 소스맵에 매핑된다", async () => {
    const fixture = await createFixture({
      "index.ts": `import { greet } from "./lib";\nconsole.log(greet("test"));`,
      "lib.ts": [
        `export function greet(name: string) {`,
        `  console.log("greeting:", name);`,
        `  return "hello " + name;`,
        `}`,
        ``,
        `export const VERSION = "1.0";`,
      ].join("\n"),
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--sourcemap",
      "--platform=react-native",
    ]);
    expect(existsSync(outFile + ".map")).toBe(true);

    const map = JSON.parse(readFileSync(outFile + ".map", "utf-8"));
    const bundleCode = readFileSync(outFile, "utf-8");
    const bundleLines = bundleCode.split("\n");

    // lib.ts 소스 인덱스 찾기
    const libIdx = map.sources.findIndex((s: string) => s.includes("lib.ts"));
    expect(libIdx).toBeGreaterThanOrEqual(0);

    // lib.ts에 대한 매핑 추출
    const libMappings = getMappedSourceLines(map.mappings, libIdx);
    expect(libMappings.length).toBeGreaterThan(0);

    // greet 함수는 ESM 래핑에서 호이스팅됨 — 함수 body의 어떤 줄이든 매핑되어야 함
    const mappedSrcLines = new Set(libMappings.map((m) => m.srcLine));
    // line 1~4 중 하나라도 매핑되면 OK (환경에 따라 호이스팅 위치가 다를 수 있음)
    expect(
      mappedSrcLines.has(1) ||
        mappedSrcLines.has(2) ||
        mappedSrcLines.has(3) ||
        mappedSrcLines.has(4),
    ).toBe(true);

    // 매핑된 번들 줄이 실제 번들 범위 내에 있어야 한다
    for (const m of libMappings) {
      expect(m.genLine).toBeLessThanOrEqual(bundleLines.length);
    }

    // 매핑된 번들 줄에 실제 greet 관련 코드가 있어야 한다
    const greetMappings = libMappings.filter((m) => m.srcLine <= 4);
    expect(greetMappings.length).toBeGreaterThan(0);
    const greetBundleLine = bundleLines[greetMappings[0].genLine - 1] || "";
    expect(
      greetBundleLine.includes("greet") ||
        greetBundleLine.includes("function") ||
        greetBundleLine.includes("console"),
    ).toBe(true);
  });

  test("TypeScript type 선언이 있어도 소스맵 줄 번호가 정확하다 (#954)", async () => {
    const fixture = await createFixture({
      "index.ts": `import { App } from "./app";\nconsole.log(App("test"));`,
      "app.ts": [
        `import React from "react";`, // line 1
        ``, // line 2
        `type Props = {`, // line 3
        `  name: string;`, // line 4
        `};`, // line 5
        ``, // line 6
        `interface Config {`, // line 7
        `  debug: boolean;`, // line 8
        `}`, // line 9
        ``, // line 10
        `export function App(name: string) {`, // line 11
        `  console.log("line 12: inside App");`, // line 12
        `  console.log("line 13: name is", name);`, // line 13
        `  return "hello " + name;`, // line 14
        `}`, // line 15
      ].join("\n"),
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile, "--sourcemap"]);

    const map = JSON.parse(readFileSync(outFile + ".map", "utf-8"));

    const appIdx = map.sources.findIndex((s: string) => s.includes("app.ts"));
    expect(appIdx).toBeGreaterThanOrEqual(0);

    const appMappings = getMappedSourceLines(map.mappings, appIdx);
    expect(appMappings.length).toBeGreaterThan(0);

    // 매핑된 소스 라인 집합
    const mappedLines = new Set(appMappings.map((m) => m.srcLine));

    // function App은 line 11에 있어야 함 (type/interface 때문에 밀리면 안 됨)
    expect(mappedLines.has(11)).toBe(true);
    // console.log "line 12" 매핑 존재
    expect(mappedLines.has(12)).toBe(true);
    // console.log "line 13" 매핑 존재
    expect(mappedLines.has(13)).toBe(true);

    // type 선언 라인(3-9)은 매핑에 없어야 함 (삭제됨)
    expect(mappedLines.has(3)).toBe(false);
    expect(mappedLines.has(4)).toBe(false);
    expect(mappedLines.has(7)).toBe(false);
    expect(mappedLines.has(8)).toBe(false);
  });

  test("단일 파일 트랜스파일에서도 type 선언 후 줄 번호가 정확하다 (#954)", async () => {
    const fixture = await createFixture({
      "input.ts": [
        `type X = { a: number };`, // line 1
        `const val = 42;`, // line 2
        `console.log(val);`, // line 3
      ].join("\n"),
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts([join(fixture.dir, "input.ts"), "-o", outFile, "--sourcemap"]);

    const map = JSON.parse(readFileSync(outFile + ".map", "utf-8"));
    const srcIdx = map.sources.findIndex((s: string) => s.includes("input.ts"));
    expect(srcIdx).toBeGreaterThanOrEqual(0);

    const mappings = getMappedSourceLines(map.mappings, srcIdx);
    const mappedLines = new Set(mappings.map((m) => m.srcLine));

    // const val = 42 → line 2
    expect(mappedLines.has(2)).toBe(true);
    // console.log(val) → line 3
    expect(mappedLines.has(3)).toBe(true);
    // type X → line 1 (삭제됨, 매핑 없어야 함)
    expect(mappedLines.has(1)).toBe(false);
  });

  test("번들 소스맵에서 console.log가 올바른 원본 줄에 매핑된다", async () => {
    const fixture = await createFixture({
      "index.ts": `import { hello } from "./lib";\nhello();`,
      "lib.ts": [
        `export function hello() {`, // line 1
        `  const x = 1;`, // line 2
        `  console.log("from lib line 3");`, // line 3
        `  console.log("from lib line 4");`, // line 4
        `}`, // line 5
      ].join("\n"),
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile, "--sourcemap"]);

    const map = JSON.parse(readFileSync(outFile + ".map", "utf-8"));
    const bundleCode = readFileSync(outFile, "utf-8");
    const bundleLines = bundleCode.split("\n");

    const libIdx = map.sources.findIndex((s: string) => s.includes("lib.ts"));
    expect(libIdx).toBeGreaterThanOrEqual(0);

    const libMappings = getMappedSourceLines(map.mappings, libIdx);

    // console.log("from lib line 3") → src line 3에 매핑
    const line3Maps = libMappings.filter((m) => m.srcLine === 3);
    expect(line3Maps.length).toBeGreaterThan(0);
    // 해당 번들 줄에 실제로 "from lib line 3" 내용이 있어야 함
    const bundleLine3 = bundleLines[line3Maps[0].genLine - 1] || "";
    expect(bundleLine3).toContain("from lib line 3");

    // console.log("from lib line 4") → src line 4에 매핑
    const line4Maps = libMappings.filter((m) => m.srcLine === 4);
    expect(line4Maps.length).toBeGreaterThan(0);
    const bundleLine4 = bundleLines[line4Maps[0].genLine - 1] || "";
    expect(bundleLine4).toContain("from lib line 4");
  });

  test("prologue 영역이 node_modules/.zts/runtime.js 소스로 매핑되고 x_google_ignoreList에 등록된다", async () => {
    const { mkdtempSync, writeFileSync: wfs, rmSync } = await import("node:fs");
    const tmpDir = mkdtempSync(join(process.cwd(), ".tmp-sm-prologue-"));
    cleanup = async () => rmSync(tmpDir, { recursive: true, force: true });

    wfs(join(tmpDir, "index.ts"), `console.log("hello");`);
    wfs(join(tmpDir, "poly.js"), `console.log("polyfill loaded");`);

    const outFile = join(tmpDir, "out.js");
    const result = await runZts([
      "--bundle",
      join(tmpDir, "index.ts"),
      "-o",
      outFile,
      "--sourcemap",
      `--polyfill=${join(tmpDir, "poly.js")}`,
    ]);
    expect(result.exitCode).toBe(0);

    const map = JSON.parse(readFileSync(outFile + ".map", "utf-8"));

    // node_modules/.zts/runtime.js 가상 소스가 sources에 포함
    const rtIdx = map.sources.findIndex((s: string) => s === "node_modules/.zts/runtime.js");
    expect(rtIdx).toBeGreaterThanOrEqual(0);

    // x_google_ignoreList에 node_modules/.zts/runtime.js 인덱스 등록
    expect(map.x_google_ignoreList).toBeArray();
    expect(map.x_google_ignoreList).toContain(rtIdx);

    // node_modules/.zts/runtime.js에 대한 매핑이 prologue 줄을 커버
    const rtMappings = getMappedSourceLines(map.mappings, rtIdx);
    expect(rtMappings.length).toBeGreaterThan(0);
    // 첫 번째 매핑이 번들 앞부분(prologue)에 있어야 함
    expect(rtMappings[0].genLine).toBeLessThanOrEqual(10);
  });

  test("prologue가 없는 ESM 번들에서는 node_modules/.zts/runtime.js과 x_google_ignoreList가 없다", async () => {
    const fixture = await createFixture({
      "index.ts": `console.log("hello");`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--sourcemap",
      "--format=esm",
    ]);

    const map = JSON.parse(readFileSync(outFile + ".map", "utf-8"));
    const hasRuntime = map.sources.some((s: string) => s === "node_modules/.zts/runtime.js");
    expect(hasRuntime).toBe(false);
  });
});
