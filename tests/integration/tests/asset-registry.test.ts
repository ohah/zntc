import { describe, test, expect } from "bun:test";
import { createFixture, createRNFixture, runZts } from "./helpers";
import { join } from "node:path";
import { readFileSync, writeFileSync } from "node:fs";

/**
 * --asset-registry / assetRegistry 통합 테스트.
 *
 * Metro AssetRegistry 호환 출력:
 *   module.exports = require("<registry>").registerAsset({
 *     __packager_asset: true, httpServerLocation, width, height, scales,
 *     hash, name, type, fileSystemLocation
 *   })
 */

// 1x1 PNG 픽셀 (빨강)
const PNG_1x1 = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
  0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x08, 0x99, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
  0x00, 0x00, 0x03, 0x00, 0x01, 0x5b, 0xf4, 0x7c, 0x3b, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
  0x44, 0xae, 0x42, 0x60, 0x82,
]);

describe("--asset-registry", () => {
  test("RN 플랫폼 프리셋 → 기본 registry 경로 자동 주입", async () => {
    const { dir, cleanup } = await createRNFixture({
      "entry.ts": `import logo from "./logo.png"; console.log(logo);`,
    });
    writeFileSync(join(dir, "logo.png"), PNG_1x1);

    const outFile = join(dir, "out.js");
    try {
      const { exitCode, stderr } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--platform=react-native",
        "--loader:.png=file",
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain("error:");
      const bundle = readFileSync(outFile, "utf8");
      // RN 프리셋이 react-native/Libraries/Image/AssetRegistry를 require_xxx 함수로 변환
      expect(bundle).toMatch(/require_+react_native[A-Za-z_]*AssetRegistry/);
      expect(bundle).toContain("registerAsset");
      expect(bundle).toContain("__packager_asset");
      expect(bundle).toContain('"width": 1');
      expect(bundle).toContain('"height": 1');
      expect(bundle).toContain('"type": "png"');
    } finally {
      await cleanup();
    }
  });

  test("--asset-registry=PATH로 커스텀 registry 경로 지정 가능", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import logo from "./logo.png"; console.log(logo);`,
      "node_modules/@my/custom-registry/package.json":
        '{"name": "@my/custom-registry", "main": "index.js"}',
      "node_modules/@my/custom-registry/index.js":
        "module.exports = { registerAsset: function(a) { return a; }, getAssetByID: function() { return null; } };\n",
    });
    writeFileSync(join(dir, "logo.png"), PNG_1x1);

    const outFile = join(dir, "out.js");
    try {
      const { exitCode } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--loader:.png=file",
        "--asset-registry=@my/custom-registry",
      ]);
      expect(exitCode).toBe(0);
      const bundle = readFileSync(outFile, "utf8");
      // custom registry path가 require_xxx 함수로 변환
      expect(bundle).toMatch(/require_+my_custom_registry/);
      expect(bundle).toContain("registerAsset");
    } finally {
      await cleanup();
    }
  });

  test("--no-asset-registry로 RN 프리셋 덮기 (URL 문자열만)", async () => {
    const { dir, cleanup } = await createRNFixture({
      "entry.ts": `import logo from "./logo.png"; console.log(logo);`,
    });
    writeFileSync(join(dir, "logo.png"), PNG_1x1);

    const outFile = join(dir, "out.js");
    try {
      const { exitCode } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--platform=react-native",
        "--loader:.png=file",
        "--no-asset-registry",
      ]);
      expect(exitCode).toBe(0);
      const bundle = readFileSync(outFile, "utf8");
      expect(bundle).not.toContain("registerAsset");
      expect(bundle).not.toContain("__packager_asset");
      // 그냥 URL 문자열로 export
      expect(bundle).toMatch(/logo-[a-f0-9]+\.png/);
    } finally {
      await cleanup();
    }
  });

  test("@2x/@3x sibling 자동 감지 → scales 배열 + variant 파일 emit", async () => {
    const { dir, cleanup } = await createRNFixture({
      "entry.ts": `import logo from "./assets/logo.png"; console.log(logo);`,
      "assets/.gitkeep": "",
    });
    writeFileSync(join(dir, "assets/logo.png"), PNG_1x1);
    writeFileSync(join(dir, "assets/logo@2x.png"), PNG_1x1);
    writeFileSync(join(dir, "assets/logo@3x.png"), PNG_1x1);

    const outDir = join(dir, "dist");
    const outFile = join(outDir, "bundle.js");
    try {
      const { exitCode } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--platform=react-native",
        "--loader:.png=file",
      ]);
      expect(exitCode).toBe(0);
      const bundle = readFileSync(outFile, "utf8");
      // scales 배열에 1, 2, 3 모두 포함
      expect(bundle).toContain('"scales": [1, 2, 3]');

      // variant 파일들이 출력 디렉토리에 각각 생성됨
      const { readdirSync } = await import("node:fs");
      const files = readdirSync(outDir);
      const variantFiles = files.filter((f) => f.includes("@2x") || f.includes("@3x"));
      expect(variantFiles.length).toBe(2);
    } finally {
      await cleanup();
    }
  });

  test("variant 없이 base만 있으면 scales=[1]", async () => {
    const { dir, cleanup } = await createRNFixture({
      "entry.ts": `import logo from "./logo.png"; console.log(logo);`,
    });
    writeFileSync(join(dir, "logo.png"), PNG_1x1);

    const outFile = join(dir, "out.js");
    try {
      const { exitCode } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--platform=react-native",
        "--loader:.png=file",
      ]);
      expect(exitCode).toBe(0);
      const bundle = readFileSync(outFile, "utf8");
      expect(bundle).toContain('"scales": [1]');
    } finally {
      await cleanup();
    }
  });

  test("비-RN 플랫폼 + registry 미지정 → 일반 URL 문자열 (기존 동작 유지)", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import logo from "./logo.png"; console.log(logo);`,
    });
    writeFileSync(join(dir, "logo.png"), PNG_1x1);

    const outFile = join(dir, "out.js");
    try {
      const { exitCode } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--loader:.png=file",
      ]);
      expect(exitCode).toBe(0);
      const bundle = readFileSync(outFile, "utf8");
      expect(bundle).not.toContain("registerAsset");
    } finally {
      await cleanup();
    }
  });

  test("손상된 PNG 헤더 — width/height=0이지만 빌드는 성공", async () => {
    const { dir, cleanup } = await createRNFixture({
      "entry.ts": `import logo from "./broken.png"; console.log(logo);`,
    });
    // PNG signature 없이 임의 바이트 — extractDimensions가 null 반환 → width/height=0
    writeFileSync(join(dir, "broken.png"), Buffer.from("not a real png file content"));

    const outFile = join(dir, "out.js");
    try {
      const { exitCode } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--platform=react-native",
        "--loader:.png=file",
      ]);
      expect(exitCode).toBe(0);
      const bundle = readFileSync(outFile, "utf8");
      // 손상된 헤더라도 registerAsset 호출은 emit. 단 dimension은 0.
      expect(bundle).toContain("registerAsset");
      expect(bundle).toContain('"width": 0');
      expect(bundle).toContain('"height": 0');
    } finally {
      await cleanup();
    }
  });

  test("확장자 대소문자 — .PNG도 file loader 매칭", async () => {
    const { dir, cleanup } = await createRNFixture({
      "entry.ts": `import logo from "./LOGO.PNG"; console.log(logo);`,
    });
    writeFileSync(join(dir, "LOGO.PNG"), PNG_1x1);

    const outFile = join(dir, "out.js");
    try {
      const { exitCode } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--platform=react-native",
        "--loader:.PNG=file",
      ]);
      expect(exitCode).toBe(0);
      const bundle = readFileSync(outFile, "utf8");
      // .PNG 로더가 매칭되어 registerAsset emit (react-native 패키지 require 자체는
      // fixture에 RN 없어도 emit은 됨 — 대소문자 매칭 검증 목적이므로 OK)
      expect(bundle).toContain("registerAsset");
    } finally {
      await cleanup();
    }
  });

  test("base 없이 @2x만 있으면 base 모듈 import는 실패", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import logo from "./assets/logo.png"; console.log(logo);`,
      "assets/.gitkeep": "",
    });
    // base는 없고 @2x만
    writeFileSync(join(dir, "assets/logo@2x.png"), PNG_1x1);

    const outFile = join(dir, "out.js");
    try {
      const { stderr } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--platform=react-native",
        "--loader:.png=file",
      ]);
      // base 파일 없으니 resolve 자체가 실패해야 함
      expect(stderr.toLowerCase()).toContain("cannot resolve");
    } finally {
      await cleanup();
    }
  });
});
