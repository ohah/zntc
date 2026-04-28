import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { envToDefine, loadEnv } from "./load-env.ts";

describe("loadEnv", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-load-env-"));
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  function reset() {
    rmSync(dir, { recursive: true, force: true });
    mkdirSync(dir);
  }

  test(".env 파일이 없으면 빈 객체", () => {
    reset();
    expect(loadEnv("production", dir)).toEqual({});
  });

  test(".env 단일 파일: prefix 일치 키만 노출", () => {
    reset();
    writeFileSync(
      join(dir, ".env"),
      "VITE_API=https://api.example.com\nSECRET_KEY=hidden\nZTS_FLAG=on",
    );
    const env = loadEnv("production", dir);
    expect(env).toEqual({
      VITE_API: "https://api.example.com",
      ZTS_FLAG: "on",
    });
    expect(env.SECRET_KEY).toBeUndefined();
  });

  test("4단계 우선순위: .env < .env.local < .env.{mode} < .env.{mode}.local", () => {
    reset();
    writeFileSync(join(dir, ".env"), "VITE_KEY=base");
    writeFileSync(join(dir, ".env.local"), "VITE_KEY=local");
    writeFileSync(join(dir, ".env.production"), "VITE_KEY=prod");
    writeFileSync(join(dir, ".env.production.local"), "VITE_KEY=prod-local");
    expect(loadEnv("production", dir).VITE_KEY).toBe("prod-local");

    rmSync(join(dir, ".env.production.local"));
    expect(loadEnv("production", dir).VITE_KEY).toBe("prod");

    rmSync(join(dir, ".env.production"));
    expect(loadEnv("production", dir).VITE_KEY).toBe("local");

    rmSync(join(dir, ".env.local"));
    expect(loadEnv("production", dir).VITE_KEY).toBe("base");
  });

  test("mode 별 분기: development 모드는 .env.development 사용", () => {
    reset();
    writeFileSync(join(dir, ".env"), "VITE_HOST=base");
    writeFileSync(join(dir, ".env.development"), "VITE_HOST=dev");
    writeFileSync(join(dir, ".env.production"), "VITE_HOST=prod");
    expect(loadEnv("development", dir).VITE_HOST).toBe("dev");
    expect(loadEnv("production", dir).VITE_HOST).toBe("prod");
    expect(loadEnv("staging", dir).VITE_HOST).toBe("base");
  });

  test("커스텀 prefix: 단일 string + 배열 둘 다 지원", () => {
    reset();
    writeFileSync(join(dir, ".env"), "VITE_A=1\nMY_B=2\nNEXT_PUBLIC_C=3");
    expect(loadEnv("production", dir, "MY_")).toEqual({ MY_B: "2" });
    expect(loadEnv("production", dir, ["MY_", "NEXT_PUBLIC_"])).toEqual({
      MY_B: "2",
      NEXT_PUBLIC_C: "3",
    });
  });

  test("주석 / 빈 라인 / invalid 키 무시", () => {
    reset();
    writeFileSync(
      join(dir, ".env"),
      [
        "# top comment",
        "",
        "VITE_OK=1",
        "# inline comment is whole-line only",
        "  VITE_TRIM = 2  ",
        "1INVALID=skipped",
        "=onlyEqual",
      ].join("\n"),
    );
    expect(loadEnv("production", dir)).toEqual({
      VITE_OK: "1",
      VITE_TRIM: "2",
    });
  });

  test("따옴표로 감싼 값은 따옴표 제거", () => {
    reset();
    writeFileSync(
      join(dir, ".env"),
      `VITE_DOUBLE="hello world"\nVITE_SINGLE='single quoted'\nVITE_PLAIN=plain`,
    );
    expect(loadEnv("production", dir)).toEqual({
      VITE_DOUBLE: "hello world",
      VITE_SINGLE: "single quoted",
      VITE_PLAIN: "plain",
    });
  });

  test("value 안의 = 보존", () => {
    reset();
    writeFileSync(join(dir, ".env"), "VITE_URL=https://example.com?q=1&r=2");
    expect(loadEnv("production", dir).VITE_URL).toBe("https://example.com?q=1&r=2");
  });
});

describe("envToDefine", () => {
  test("MODE/PROD/DEV/SSR 자동 주입 + 사용자 키 포함", () => {
    const define = envToDefine({ VITE_API: "https://api" }, "production");
    expect(define).toEqual({
      "import.meta.env.MODE": '"production"',
      "import.meta.env.PROD": "true",
      "import.meta.env.DEV": "false",
      "import.meta.env.SSR": "false",
      "import.meta.env.VITE_API": '"https://api"',
    });
  });

  test("development mode: PROD=false, DEV=true", () => {
    const define = envToDefine({}, "development");
    expect(define["import.meta.env.PROD"]).toBe("false");
    expect(define["import.meta.env.DEV"]).toBe("true");
  });

  test("값에 따옴표/특수문자 있어도 JSON.stringify 로 안전하게 직렬화", () => {
    const define = envToDefine({ VITE_QUOTE: 'has "quotes" and \\backslash' }, "production");
    expect(define["import.meta.env.VITE_QUOTE"]).toBe('"has \\"quotes\\" and \\\\backslash"');
  });
});
