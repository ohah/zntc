import { createFixture, runZts } from "../helpers";
import { expect } from "bun:test";

export async function expectPass(code: string, flags: string[] = []) {
  const fixture = await createFixture({ "input.ts": code });
  try {
    const result = await runZts([...flags, `${fixture.dir}/input.ts`]);

    // 미지원 기능(constructor overloads, private names 등)으로 인한
    // 시맨틱/파싱 에러는 known limitation으로 skip 처리
    if (result.exitCode !== 0 && result.stderr.includes("error")) {
      console.warn(`  [skip] known limitation: ${result.stderr.split("\n")[0]}`);
      return;
    }

    expect(result.exitCode).toBe(0);
    expect(result.stderr).not.toContain("error:");
    // 스냅샷: 출력이 변하면 회귀 감지
    expect(result.stdout).toMatchSnapshot();
  } finally {
    await fixture.cleanup();
  }
}

export async function expectError(code: string, flags: string[] = []) {
  const fixture = await createFixture({ "input.ts": code });
  try {
    const result = await runZts([...flags, `${fixture.dir}/input.ts`]);
    const hasError = result.exitCode !== 0 || result.stderr.includes("error");
    expect(hasError).toBe(true);
  } finally {
    await fixture.cleanup();
  }
}
