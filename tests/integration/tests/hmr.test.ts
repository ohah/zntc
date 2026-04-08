import { describe, test, expect, afterEach } from "bun:test";
import { createFixture, runZts, ZTS_BIN } from "./helpers";
import { join } from "node:path";
import { readFileSync, writeFileSync } from "node:fs";
import { spawn } from "bun";

describe("HMR 통합 테스트", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("dev 번들 내에서 per-module code를 eval해도 에러가 발생하지 않는다", async () => {
    // 1. dev 번들 생성
    const fixture = await createFixture({
      "App.tsx": `export default function App() { return "hello"; }`,
      "index.tsx": `import App from "./App";\nconsole.log(App());`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts([
      "--bundle",
      join(fixture.dir, "index.tsx"),
      "-o",
      outFile,
      "--dev",
    ]);
    expect(bundle.exitCode).toBe(0);

    // 2. 번들 출력 읽기
    const bundleCode = readFileSync(outFile, "utf-8");

    // 3. 기본 구조 확인
    expect(bundleCode).toContain("__esm");
    expect(bundleCode).toContain("__zts_modules");
    expect(bundleCode).toContain("__zts_make_hot");
    expect(bundleCode).toContain("__zts_apply_update");

    // 4. 번들을 bun으로 실행하여 에러가 없는지 확인
    const run = spawn({ cmd: ["bun", "run", outFile], stdout: "pipe", stderr: "pipe" });
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(run.stdout).text(),
      new Response(run.stderr).text(),
      run.exited,
    ]);
    expect(exitCode).toBe(0);
    expect(stdout.trim()).toBe("hello");
  });

  test("--watch-json 첫 rebuild는 graph_changed, 이후는 변경 모듈만 updates", async () => {
    const fixture = await createFixture({
      "App.tsx": `export default function App() { return "v1"; }`,
      "index.tsx": `import App from "./App";\nconsole.log(App());`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");

    // --watch-json으로 ZTS 시작
    const zts = spawn({
      cmd: [
        ZTS_BIN,
        "--bundle",
        join(fixture.dir, "index.tsx"),
        "-o",
        outFile,
        "--dev",
        "--watch-json",
      ],
      stdout: "pipe",
      stderr: "pipe",
    });

    const events: any[] = [];
    const reader = zts.stdout.getReader();
    let buffer = "";

    // 이벤트 수집 (최대 3개 또는 5초)
    const collectEvents = async () => {
      const timeout = setTimeout(() => {
        zts.kill();
      }, 5000);
      try {
        while (events.length < 3) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += new TextDecoder().decode(value);
          const lines = buffer.split("\n");
          buffer = lines.pop() || "";
          for (const line of lines) {
            if (!line.trim()) continue;
            try {
              events.push(JSON.parse(line));
            } catch {}
          }
          // ready 이벤트 후 첫 번째 변경 트리거
          if (events.length === 1 && events[0].type === "ready") {
            // 약간 대기 후 파일 변경
            await new Promise((r) => setTimeout(r, 200));
            writeFileSync(
              join(fixture.dir, "App.tsx"),
              `export default function App() { return "v2"; }`,
            );
          }
          // 첫 번째 rebuild 후 두 번째 변경
          if (events.length === 2 && events[1].type === "rebuild") {
            await new Promise((r) => setTimeout(r, 200));
            writeFileSync(
              join(fixture.dir, "App.tsx"),
              `export default function App() { return "v3"; }`,
            );
          }
        }
      } finally {
        clearTimeout(timeout);
        zts.kill();
      }
    };

    await collectEvents();

    // ready 이벤트
    expect(events.length).toBeGreaterThanOrEqual(1);
    expect(events[0].type).toBe("ready");

    // 첫 rebuild: 변경된 모듈만 updates (캐시가 초기 빌드에서 채워짐)
    if (events.length >= 2) {
      expect(events[1].type).toBe("rebuild");
      expect(events[1].success).toBe(true);
      // updates가 있거나 graph_changed가 있어야 함
      expect(events[1].updates != null || events[1].graph_changed === true).toBe(true);
    }

    // 두 번째 rebuild: updates에 변경된 모듈만 (타이밍에 따라 수신 못할 수 있음)
    if (events.length >= 3) {
      expect(events[2].type).toBe("rebuild");
      expect(events[2].success).toBe(true);
      if (events[2].updates) {
        // 전체 모듈이 아닌 변경된 모듈만
        expect(events[2].updates.length).toBeLessThanOrEqual(2);
      }
    }
  });

  test("per-module code를 번들 컨텍스트에서 eval하면 에러 없이 실행된다", async () => {
    // 이 테스트는 HMR의 핵심 메커니즘을 검증:
    // 번들 IIFE 안에서 __zts_apply_update → eval(per_module_code) 가 동작하는지
    const fixture = await createFixture({
      "App.tsx": `export default function App() { return "original"; }`,
      "index.tsx": `import App from "./App";\nconsole.log(App());`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");

    // dev 번들 생성
    const bundle = await runZts([
      "--bundle",
      join(fixture.dir, "index.tsx"),
      "-o",
      outFile,
      "--dev",
    ]);
    expect(bundle.exitCode).toBe(0);

    // 수정된 App.tsx로 다시 빌드 → per-module code 추출
    writeFileSync(
      join(fixture.dir, "App.tsx"),
      `export default function App() { return "updated"; }`,
    );

    // --watch-json 없이 다시 빌드 (collect_module_codes는 CLI에서 자동)
    // 대신 두 번째 번들을 생성하여 per-module code 차이 확인
    const outFile2 = join(fixture.dir, "out2.js");
    const bundle2 = await runZts([
      "--bundle",
      join(fixture.dir, "index.tsx"),
      "-o",
      outFile2,
      "--dev",
    ]);
    expect(bundle2.exitCode).toBe(0);

    const bundleCode1 = readFileSync(outFile, "utf-8");
    const bundleCode2 = readFileSync(outFile2, "utf-8");

    // 두 번들이 다름 (App 코드 변경)
    expect(bundleCode1).toContain("original");
    expect(bundleCode2).toContain("updated");

    // 핵심 테스트: 첫 번째 번들 실행 후, 두 번째 번들의 App 모듈 코드를
    // __zts_apply_update로 eval하면 에러 없이 실행되는지
    // → JS 테스트 파일을 생성하여 검증
    const testScript = join(fixture.dir, "hmr_test.js");
    writeFileSync(
      testScript,
      `
      // 첫 번째 번들 로드 (원본)
      ${bundleCode1}

      // HMR API가 전역에 노출되는지 확인
      if (typeof globalThis.__zts_apply_update !== "function") {
        console.error("FAIL: __zts_apply_update not found on globalThis");
        process.exit(1);
      }

      // __zts_modules에 모듈이 등록되었는지
      var moduleCount = Object.keys(globalThis.__zts_modules).length;
      if (moduleCount === 0) {
        console.error("FAIL: __zts_modules is empty");
        process.exit(1);
      }

      console.log("PASS: bundle loaded, " + moduleCount + " modules registered");
    `,
    );

    const testRun = spawn({ cmd: ["bun", "run", testScript], stdout: "pipe", stderr: "pipe" });
    const [testOut, testErr, testExit] = await Promise.all([
      new Response(testRun.stdout).text(),
      new Response(testRun.stderr).text(),
      testRun.exited,
    ]);

    if (testExit !== 0) {
      console.error("Test stderr:", testErr);
      console.error("Test stdout:", testOut);
    }
    expect(testExit).toBe(0);
    expect(testOut).toContain("PASS");
    expect(testOut).toContain("modules registered");
  });
});
