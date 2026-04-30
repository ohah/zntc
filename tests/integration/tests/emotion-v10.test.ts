import { describe, it, expect, afterEach } from "bun:test";
import {
  createFixture,
  hasEmotionV10Fixture,
  EMOTION_V10_FIXTURE_NODE_MODULES,
  linkNodeModules,
  runZtsInDir,
} from "./helpers";
import { join } from "node:path";
import { readFile } from "node:fs/promises";

// emotion v10 (legacy) 사용자 커버리지.
// v10 의 entry (`@emotion/core`) 가 v11 (`@emotion/react`) 와 별도 패키지라 같은
// node_modules 트리에 공존이 어려움. `tests/integration/fixtures/emotion-v10/` 에
// 격리 설치 (`bun install`) — fixture 가 없으면 모든 테스트 skip.

const hasV10 = hasEmotionV10Fixture();

const V10_CSS_PACKAGES = [
  "@emotion/core",
  "@emotion/css",
  "@emotion/cache",
  "@emotion/serialize",
  "@emotion/sheet",
  "@emotion/utils",
  "@emotion/hash",
  "@emotion/unitless",
  "@emotion/memoize",
  "@emotion/stylis",
  "@emotion/weak-memoize",
];

const V10_STYLED_PACKAGES = [
  ...V10_CSS_PACKAGES,
  "@emotion/styled",
  "@emotion/styled-base",
  "@emotion/is-prop-valid",
];

/// v10 fixture 패키지 + emotion config 로 번들. 9× boilerplate 흡수.
/// 번들이 실패 (exitCode != 0) 하면 stderr 를 포함해 throw — silent 빈 `out` 으로
/// 다운스트림 assertion 이 헷갈리는 메시지를 내는 것을 방지.
async function runV10Bundle(opts: {
  source: string;
  config: object;
  /** 기본 `index.ts`. JSX 가 필요하면 `index.tsx` 로 override. */
  entry?: string;
  /** 기본 V10_CSS_PACKAGES. styled 가 필요하면 V10_STYLED_PACKAGES. */
  packages?: string[];
}): Promise<{ out: string; cleanup: () => Promise<void>; exitCode: number }> {
  const entry = opts.entry ?? "index.ts";
  const fixture = await createFixture({
    [entry]: opts.source,
    "zts.config.json": JSON.stringify(opts.config),
  });
  await linkNodeModules(fixture.dir, opts.packages ?? V10_CSS_PACKAGES, {
    extraRoots: [EMOTION_V10_FIXTURE_NODE_MODULES],
  });

  const outFile = join(fixture.dir, "out.js");
  const result = await runZtsInDir(fixture.dir, ["--bundle", entry, "-o", outFile], {
    bin: "js",
  });
  if (result.exitCode !== 0) {
    await fixture.cleanup();
    throw new Error(
      `zts bundle failed (exit ${result.exitCode})\nstderr:\n${result.stderr}\nstdout:\n${result.stdout}`,
    );
  }
  const out = await readFile(outFile, "utf-8");
  return { out, cleanup: fixture.cleanup, exitCode: result.exitCode };
}

describe.skipIf(!hasV10)("Emotion v10 — autoLabel + 번들링", () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // ─── @emotion/core (v10 메인 entry) ───

  it("@emotion/core css binding — autoLabel prepend", async () => {
    const r = await runV10Bundle({
      source: `
        import { css } from "@emotion/core";
        const card = css\`color: hotpink; font-size: 20px;\`;
        console.log(card);
      `,
      config: { compiler: { emotion: true } },
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.out).toContain("label:card;");
    expect(r.out).toContain("color: hotpink");
  });

  it("@emotion/core keyframes — autoLabel prepend", async () => {
    const r = await runV10Bundle({
      source: `
        import { keyframes } from "@emotion/core";
        const fadeIn = keyframes\`from { opacity: 0; } to { opacity: 1; }\`;
        console.log(fadeIn);
      `,
      config: { compiler: { emotion: true } },
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.out).toContain("label:fadeIn;");
    expect(r.out).toContain("opacity: 0");
  });

  it("@emotion/core css + keyframes 동시 import — 양쪽 다 인식", async () => {
    const r = await runV10Bundle({
      source: `
        import { css, keyframes } from "@emotion/core";
        const spin = keyframes\`from { rotate: 0; } to { rotate: 360deg; }\`;
        const card = css\`color: red; animation: \${spin} 1s linear;\`;
        console.log(card);
      `,
      config: { compiler: { emotion: true } },
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.out).toContain("label:spin;");
    expect(r.out).toContain("label:card;");
  });

  // ─── @emotion/styled v10 (default styled) ───

  it("@emotion/styled v10 — styled.div 도 autoLabel", async () => {
    const r = await runV10Bundle({
      source: `
        import styled from "@emotion/styled";
        const Btn = styled.div\`color: white; background: dodgerblue;\`;
        console.log(Btn);
      `,
      config: { compiler: { emotion: true } },
      packages: V10_STYLED_PACKAGES,
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.out).toContain("label:Btn;");
    expect(r.out).toContain("dodgerblue");
  });

  it("@emotion/styled v10 — styled(Component) chain 도 인식", async () => {
    const r = await runV10Bundle({
      source: `
        import styled from "@emotion/styled";
        const Inner = (props: any) => null;
        const Wrapped = styled(Inner)\`color: blue;\`;
        console.log(Wrapped);
      `,
      config: { compiler: { emotion: true } },
      packages: V10_STYLED_PACKAGES,
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.out).toContain("label:Wrapped;");
  });

  // ─── JSX inline css prop (v10 jsx pragma 패턴) ───

  it("@emotion/core JSX inline `<div css={css`...`}>` autoLabel", async () => {
    const r = await runV10Bundle({
      source: `
        /** @jsx jsx */
        import { jsx, css } from "@emotion/core";
        const el = <div css={css\`color: hotpink;\`}>hello</div>;
        console.log(el);
      `,
      entry: "index.tsx",
      config: { compiler: { emotion: true } },
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.out).toContain("label:div;");
    expect(r.out).toContain("hotpink");
  });

  // ─── 옵션 비활성 / 격리 검증 ───

  it("emotion 비활성 — v10 패키지 import 해도 label 추가 안 됨", async () => {
    const r = await runV10Bundle({
      source: `
        import { css } from "@emotion/core";
        const card = css\`color: red;\`;
        console.log(card);
      `,
      config: { compiler: { emotion: false } },
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    // emotion v10 런타임 자체에 `label:` 문자열이 있어 단순 substring 검사로는 부족.
    // 우리 transform 이 prepend 하는 `label:<var>;` 패턴을 직접 확인.
    expect(r.out).not.toContain("label:card;");
    expect(r.out).toContain("color: red");
  });

  it("autoLabel 명시적 disable — v10 에서도 옵션 존중", async () => {
    const r = await runV10Bundle({
      source: `
        import { css } from "@emotion/core";
        const card = css\`color: red;\`;
        console.log(card);
      `,
      config: { compiler: { emotion: { autoLabel: false } } },
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.out).not.toContain("label:card;");
    expect(r.out).toContain("color: red");
  });

  // ─── Global / injectGlobal (v10) ───

  it("@emotion/css v10 — injectGlobal binding autoLabel", async () => {
    const r = await runV10Bundle({
      source: `
        import { injectGlobal } from "@emotion/css";
        const reset = injectGlobal\`* { box-sizing: border-box; }\`;
        console.log(reset);
      `,
      config: { compiler: { emotion: true } },
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.out).toContain("label:reset;");
    expect(r.out).toContain("box-sizing: border-box");
  });

  it("@emotion/core v10 — <Global styles={css`...`}> autoLabel", async () => {
    const r = await runV10Bundle({
      source: `
        /** @jsx jsx */
        import { jsx, css, Global } from "@emotion/core";
        const el = <Global styles={css\`body { color: red; }\`} />;
        console.log(el);
      `,
      entry: "index.tsx",
      config: { compiler: { emotion: true } },
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.out).toContain("label:Global;");
    expect(r.out).toContain("color: red");
  });

  // ─── sourceMap (babel-plugin-emotion 호환) ───

  it("@emotion/core v10 — sourceMap: true 일 때 inline sourceMap 주석 추가", async () => {
    const r = await runV10Bundle({
      source: `
        import { css } from "@emotion/core";
        const card = css\`color: hotpink;\`;
        console.log(card);
      `,
      config: { compiler: { emotion: { sourceMap: true } } },
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.out).toContain("label:card;");
    expect(r.out).toContain("/*# sourceMappingURL=data:application/json;charset=utf-8;base64,");
    // base64 안에 source filename 이 인코딩됐는지 (decoding 검증은 unit 테스트가 함)
    expect(r.out).toContain("hotpink");
  });

  it("v10 격리 검증 — fixture 의 @emotion/core 가 v10.x 인지", async () => {
    const pkgPath = join(EMOTION_V10_FIXTURE_NODE_MODULES, "@emotion/core/package.json");
    const pkg = JSON.parse(await readFile(pkgPath, "utf-8"));
    expect(pkg.version).toMatch(/^10\./);
  });
});
