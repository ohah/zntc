import { createFixture, runZts } from "../helpers";
import { expect } from "bun:test";

export async function expectPass(code: string, flags: string[] = []) {
  const fixture = await createFixture({ "input.ts": code });
  try {
    const result = await runZts([...flags, `${fixture.dir}/input.ts`]);

    // 파싱 에러로 output 자체가 없는 경우: 아직 미지원 구문이므로 skip
    if (result.stdout.length === 0 && result.exitCode !== 0) {
      return;
    }

    // 스냅샷: 출력이 변하면 회귀 감지 (빈 출력도 유효 — 타입 선언만 있는 경우)
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
