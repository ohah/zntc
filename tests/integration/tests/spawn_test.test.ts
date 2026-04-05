import { test, expect } from "bun:test";
import { spawn } from "bun";

test("spawn echo in bun test", async () => {
  const proc = spawn({ cmd: ["echo", "hello"], stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  console.log(
    "exitCode:",
    exitCode,
    "stdout:",
    JSON.stringify(stdout),
    "stderr:",
    JSON.stringify(stderr),
  );
  expect(exitCode).toBe(0);
});
