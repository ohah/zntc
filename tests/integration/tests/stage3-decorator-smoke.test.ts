import { describe, it, expect, afterEach } from "bun:test";
import { createFixture, runZts } from "./helpers";
import { join, resolve } from "node:path";
import { symlink, mkdir, readFile } from "node:fs/promises";
import { spawnSync } from "bun";

// Stage 3 Decorator 스모크 테스트
// 실제 라이브러리(MobX 6)를 사용하여 Stage 3 decorator가 런타임에서 올바르게 동작하는지 검증

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");

// CI에서 mobx가 설치되지 않았으면 전체 suite skip
const hasMobx = await (async () => {
  try {
    const { statSync } = await import("node:fs");
    statSync(join(PROJECT_ROOT, "node_modules/mobx/package.json"));
    return true;
  } catch {
    return false;
  }
})();

async function mobxSmoke(code: string, extraArgs: string[] = []) {
  const { dir, cleanup } = await createFixture({ "index.ts": code });

  await mkdir(join(dir, "node_modules"), { recursive: true });
  try {
    await symlink(join(PROJECT_ROOT, "node_modules/mobx"), join(dir, "node_modules/mobx"));
  } catch {}

  const outFile = join(dir, "out.js");
  const bundle = await runZts(["--bundle", join(dir, "index.ts"), "-o", outFile, ...extraArgs]);
  if (bundle.exitCode !== 0) {
    await cleanup();
    throw new Error("bundle failed: " + bundle.stderr);
  }

  // spawnSync로 실행 — pipe 문제 회피
  const run = spawnSync(["bun", "run", outFile]);
  const output = run.stdout.toString().trim();
  const stderr = run.stderr.toString().trim();

  return { output, stderr, exitCode: run.exitCode, cleanup };
}

describe.skipIf(!hasMobx)("Stage 3 Decorator Smoke — MobX 6", () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  it("@observable accessor + @action + autorun", async () => {
    const r = await mobxSmoke(`
      import { makeObservable, observable, action, autorun } from "mobx";
      class Counter {
        @observable accessor count = 0;
        @action increment() { this.count++; }
        constructor() { makeObservable(this); }
      }
      const c = new Counter();
      const log: number[] = [];
      autorun(() => { log.push(c.count); });
      c.increment();
      c.increment();
      c.increment();
      console.log(log.join(","));
    `);
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.output).toContain("0,1,2,3");
  });

  it("@computed getter", async () => {
    const r = await mobxSmoke(`
      import { makeObservable, observable, computed, action } from "mobx";
      class Store {
        @observable accessor firstName = "John";
        @observable accessor lastName = "Doe";
        @computed get fullName() { return this.firstName + " " + this.lastName; }
        @action setName(f: string, l: string) { this.firstName = f; this.lastName = l; }
        constructor() { makeObservable(this); }
      }
      const s = new Store();
      console.log(s.fullName);
      s.setName("Jane", "Smith");
      console.log(s.fullName);
    `);
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.output).toContain("John Doe");
    expect(r.output).toContain("Jane Smith");
  });

  it("@observable accessor toggle", async () => {
    const r = await mobxSmoke(`
      import { makeObservable, observable, action, autorun } from "mobx";
      class Todo {
        @observable accessor done = false;
        @action toggle() { this.done = !this.done; }
        constructor() { makeObservable(this); }
      }
      const t = new Todo();
      const s: string[] = [];
      autorun(() => { s.push(t.done ? "done" : "pending"); });
      t.toggle();
      t.toggle();
      console.log(s.join(","));
    `);
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.output).toContain("pending,done,pending");
  });

  // --- #1389 회귀 가드: --target=es5 에서도 MobX 6 decorator + accessor 동작 ---

  it("#1389: @observable accessor + @action — --target=es5", async () => {
    const r = await mobxSmoke(
      `
      import { makeObservable, observable, action, autorun } from "mobx";
      class Counter {
        @observable accessor count = 0;
        @action increment() { this.count++; }
        constructor() { makeObservable(this); }
      }
      const c = new Counter();
      const log: number[] = [];
      autorun(() => { log.push(c.count); });
      c.increment();
      c.increment();
      c.increment();
      console.log(log.join(","));
    `,
      ["--target=es5"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.output).toContain("0,1,2,3");
  });

  it("#1389: @computed getter chain — --target=es5", async () => {
    const r = await mobxSmoke(
      `
      import { makeObservable, observable, computed, action } from "mobx";
      class Store {
        @observable accessor firstName = "John";
        @observable accessor lastName = "Doe";
        @computed get fullName() { return this.firstName + " " + this.lastName; }
        @action setName(f: string, l: string) { this.firstName = f; this.lastName = l; }
        constructor() { makeObservable(this); }
      }
      const s = new Store();
      console.log(s.fullName);
      s.setName("Jane", "Smith");
      console.log(s.fullName);
    `,
      ["--target=es5"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.output).toContain("John Doe");
    expect(r.output).toContain("Jane Smith");
  });
});
