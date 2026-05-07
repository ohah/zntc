#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import { readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const coverageDir = join(tmpdir(), `zntc-runtime-polyfill-coverage-${process.pid}`);
rmSync(coverageDir, { recursive: true, force: true });

const test = spawnSync(
  "bun",
  [
    "test",
    "--coverage",
    "--coverage-reporter=lcov",
    `--coverage-dir=${coverageDir}`,
    "packages/core/src/runtime-polyfills.test.ts",
  ],
  { stdio: "inherit" },
);

if (test.status !== 0) process.exit(test.status ?? 1);

const lcov = readFileSync(join(coverageDir, "lcov.info"), "utf8");
rmSync(coverageDir, { recursive: true, force: true });

const record = lcov
  .split("end_of_record")
  .find((entry) => entry.includes("SF:packages/core/src/runtime-polyfills.ts"));

if (!record) {
  console.error("runtime-polyfills coverage record not found");
  process.exit(1);
}

function numberField(name) {
  const match = record.match(new RegExp(`^${name}:(\\d+)`, "m"));
  return match ? Number(match[1]) : null;
}

const checks = [
  ["line", numberField("LH"), numberField("LF")],
  ["function", numberField("FNH"), numberField("FNF")],
];

const branchHit = numberField("BRH");
const branchFound = numberField("BRF");
if (branchHit !== null || branchFound !== null) checks.push(["branch", branchHit, branchFound]);

let failed = false;
for (const [name, hit, found] of checks) {
  if (hit === null || found === null || hit !== found) {
    console.error(`runtime-polyfills ${name} coverage is not 100%: ${hit ?? 0}/${found ?? 0}`);
    failed = true;
  }
}

if (failed) process.exit(1);
console.log("runtime-polyfills coverage: 100% line/function coverage");
