import { describe, test, expect } from "bun:test";
import { ZTS_BIN } from "./helpers";
import { resolve } from "node:path";

/**
 * React Native ES5 다운레벨링 회귀 테스트.
 * 실제 RN Libraries 파일을 --target=es5 --flow로 트랜스파일하여
 * 크래시(panic) 없이 변환되는지 검증한다.
 *
 * 검증 항목:
 * - async/await → __async(__generator(state machine)) 변환
 * - class → function + prototype 변환
 * - destructuring default parameter → temp 변수
 * - JSX member expression (</React.Fragment>)
 * - yield/await in expression position
 */

const FIXTURES = resolve(import.meta.dir, "fixtures/react-native");

async function transpileES5(file: string): Promise<{
  exitCode: number;
  stdout: string;
  stderr: string;
}> {
  const filePath = resolve(FIXTURES, file);
  const proc = Bun.spawnSync([ZTS_BIN, "--target=es5", "--flow", "--jsx-in-js", filePath]);
  return {
    exitCode: proc.exitCode,
    stdout: proc.stdout.toString(),
    stderr: proc.stderr.toString(),
  };
}

async function expectES5Pass(file: string) {
  const result = await transpileES5(file);
  expect(result.exitCode).toBe(0);
  // panic이나 thread 에러가 없어야 함
  expect(result.stderr).not.toContain("panic");
  expect(result.stderr).not.toContain("thread");
  // yield/function*이 출력에 남아있으면 안 됨
  expect(result.stdout).not.toContain("yield ");
  expect(result.stdout).not.toContain("function*");
  // async function이 남아있으면 안 됨 (__async 헬퍼 제외)
  expect(result.stdout).not.toMatch(/(?<!_)async function/);
}

describe("RN ES5 다운레벨링: async/generator/class", () => {
  // AnimatedImplementation.js — destructuring default + spread 조합
  test("Animated/AnimatedImplementation.js", () =>
    expectES5Pass("Animated/AnimatedImplementation.js"));

  // KeyboardAvoidingView.js — class async method + await in if condition
  test("Components/Keyboard/KeyboardAvoidingView.js", () =>
    expectES5Pass("Components/Keyboard/KeyboardAvoidingView.js"));

  // FlatList.js — JSX member expression (React.Fragment)
  test("Lists/FlatList.js", () => expectES5Pass("Lists/FlatList.js"));

  // PermissionsAndroid.js — async method
  test("PermissionsAndroid/PermissionsAndroid.js", () =>
    expectES5Pass("PermissionsAndroid/PermissionsAndroid.js"));
});

describe("RN ES5: ExampleApp 번들 테스트", () => {
  const EXAMPLE_APP = resolve(import.meta.dir, "fixtures/rn-example-app");

  test("bun install + bundle (no target)", async () => {
    // bun install로 node_modules 설치
    const install = Bun.spawnSync(["bun", "install", "--frozen-lockfile"], {
      cwd: EXAMPLE_APP,
    });
    // frozen-lockfile 실패해도 설치 자체는 시도
    if (install.exitCode !== 0) {
      const install2 = Bun.spawnSync(["bun", "install"], { cwd: EXAMPLE_APP });
      expect(install2.exitCode).toBe(0);
    }

    // 번들링 (no target — ES6+ 출력)
    const bundle = Bun.spawnSync([
      ZTS_BIN,
      "--bundle",
      resolve(EXAMPLE_APP, "index.js"),
      "--platform=react-native",
      "--flow",
      "-o",
      resolve(EXAMPLE_APP, "out.js"),
    ]);
    expect(bundle.exitCode).toBe(0);
    expect(bundle.stderr.toString()).not.toContain("panic");

    // 출력 크기 확인 (최소 100KB — RN 기본 모듈 포함)
    const stat = await Bun.file(resolve(EXAMPLE_APP, "out.js")).text();
    expect(stat.length).toBeGreaterThan(100_000);
  });

  test("bundle --target=es5", async () => {
    const bundle = Bun.spawnSync([
      ZTS_BIN,
      "--bundle",
      resolve(EXAMPLE_APP, "index.js"),
      "--platform=react-native",
      "--target=es5",
      "--flow",
      "-o",
      resolve(EXAMPLE_APP, "out-es5.js"),
    ]);
    expect(bundle.exitCode).toBe(0);
    expect(bundle.stderr.toString()).not.toContain("panic");

    const output = await Bun.file(resolve(EXAMPLE_APP, "out-es5.js")).text();
    // generator 구문이 남아있으면 안 됨
    expect(output).not.toContain("function*");
    expect(output).not.toMatch(/\bfunction\s*\*/);
    // yield 키워드 체크: 문자열 리터럴 내 "yield" 오탐 방지를 위해
    // 세미콜론/줄바꿈/공백 뒤에 오는 실제 yield 키워드만 감지
    expect(output).not.toMatch(/(?:^|[;,=({\n])\s*yield[\s;]/m);
    // ES5 출력 크기 (100KB+)
    expect(output.length).toBeGreaterThan(100_000);
  });
});

describe("RN 번들: Metro vs ZTS 모듈 수 비교", () => {
  const EXAMPLE_APP = resolve(import.meta.dir, "fixtures/rn-example-app");

  test("Metro 번들 모듈 수 기준선", async () => {
    // Metro 번들
    const metro = Bun.spawnSync(
      [
        "npx",
        "react-native",
        "bundle",
        "--platform",
        "ios",
        "--dev",
        "false",
        "--entry-file",
        "index.js",
        "--bundle-output",
        resolve(EXAMPLE_APP, "metro-out.js"),
      ],
      { cwd: EXAMPLE_APP },
    );
    expect(metro.exitCode).toBe(0);

    const metroOutput = await Bun.file(resolve(EXAMPLE_APP, "metro-out.js")).text();
    const metroModules = (metroOutput.match(/^__d\(function/gm) || []).length;

    // ZTS 번들 (--rn-platform=ios: Metro의 --platform ios와 동일한 확장자 해석)
    const zts = Bun.spawnSync([
      ZTS_BIN,
      "--bundle",
      resolve(EXAMPLE_APP, "index.js"),
      "--platform=react-native",
      "--rn-platform=ios",
      "--flow",
      "--metafile=" + resolve(EXAMPLE_APP, "meta.json"),
      "-o",
      resolve(EXAMPLE_APP, "zts-out.js"),
    ]);
    expect(zts.exitCode).toBe(0);

    const meta = JSON.parse(await Bun.file(resolve(EXAMPLE_APP, "meta.json")).text());
    const ztsModules = Object.keys(meta.inputs || {}).length;

    // 로그 출력 (CI에서 확인용)
    console.log(`Metro modules: ${metroModules}, ZTS modules: ${ztsModules}`);
    console.log(
      `Metro bytes: ${metroOutput.length}, ZTS bytes: ${(await Bun.file(resolve(EXAMPLE_APP, "zts-out.js")).text()).length}`,
    );

    // ZTS가 Metro 이상의 모듈을 resolve해야 함
    const ratio = ztsModules / metroModules;
    console.log(`Module resolve ratio: ${(ratio * 100).toFixed(1)}%`);
    expect(ratio).toBeGreaterThanOrEqual(1.0);
  }, 60_000); // Metro 번들은 ~20초 소요

  test("Hermes 구문 검증 (hermesc)", async () => {
    const hermescDir = process.platform === "linux" ? "linux64-bin" : "osx-bin";
    const hermesc = resolve(
      EXAMPLE_APP,
      `node_modules/hermes-compiler/hermesc/${hermescDir}/hermesc`,
    );

    // ZTS 번들
    const outFile = resolve(EXAMPLE_APP, "zts-hermes.js");
    const zts = Bun.spawnSync([
      ZTS_BIN,
      "--bundle",
      resolve(EXAMPLE_APP, "index.js"),
      "--platform=react-native",
      "--rn-platform=ios",
      "--flow",
      "-o",
      outFile,
    ]);
    expect(zts.exitCode).toBe(0);

    // hermesc로 구문 검증
    const hbc = resolve(EXAMPLE_APP, "zts-hermes.hbc");
    const hermes = Bun.spawnSync([hermesc, "-emit-binary", "-out", hbc, outFile]);
    const stderr = hermes.stderr?.toString() ?? "";
    if (hermes.exitCode !== 0) {
      console.log("hermesc errors:", stderr);
    }
    const errorCount = (stderr.match(/error:/g) || []).length;
    console.log(`hermesc errors: ${errorCount}`);
    expect(errorCount).toBe(0);
  }, 60_000);

  test("번들 내 미변환 require() 호출 검출", async () => {
    // __commonJS 래퍼 안에서 ESM import가 require()로 변환될 때
    // require_xxx()로 치환되어야 함. raw require("specifier")가 남아있으면 런타임 에러.
    // 이전 ��스트(Hermes 구문 검증)에 의존하지 않고 자체 번들 생성
    const outFile = resolve(EXAMPLE_APP, "zts-require-check.js");
    const zts = Bun.spawnSync([
      ZTS_BIN,
      "--bundle",
      resolve(EXAMPLE_APP, "index.js"),
      "--platform=react-native",
      "--rn-platform=ios",
      "--flow",
      "-o",
      outFile,
    ]);
    expect(zts.exitCode).toBe(0);
    const output = await Bun.file(outFile).text();

    // 번들 내 raw require("...") 패턴 검출 (require_ 접두사가 아닌 것만)
    // __commonJS 런타임 정의 내의 require는 제외
    const rawRequires = output.match(/(?<!_)require\s*\(\s*["'][^"']+["']\s*\)/g) || [];

    // 현재 알려진 미해결 케이스 수 기록 (점진적 개선 추적)
    console.log(`Raw require() calls remaining: ${rawRequires.length}`);
    if (rawRequires.length > 0) {
      // 처음 5개 출력 (디버깅용)
      console.log("Examples:", rawRequires.slice(0, 5));
    }

    // scope hoisted esm_with_dynamic_fallback 내 require()는 아직 미해결이므로
    // 현재 기준선보다 악화되지 않는 것만 검증 (기준선은 점진적으로 낮춤)
    expect(rawRequires.length).toBeLessThanOrEqual(230);
  }, 60_000);
});

describe("RN ES5 다운레벨링: 기존 flow-rn fixtures", () => {
  // 기존 50개 fixtures 중 async/class가 있는 파일도 ES5로 검증
  test("Animated/AnimatedEvent.js", () => expectES5Pass("Animated/AnimatedEvent.js"));

  test("Animated/AnimatedMock.js", () => expectES5Pass("Animated/AnimatedMock.js"));

  test("Animated/Easing.js", () => expectES5Pass("Animated/Easing.js"));

  test("Alert/Alert.js", () => expectES5Pass("Alert/Alert.js"));
});
