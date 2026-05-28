#!/usr/bin/env bun
/**
 * Peak RSS 측정 + 페어드 통계 — RFC_TRANSFORMER_OWN_AST PR-2 검증용.
 *
 * 두 zntc 바이너리 (main / PR) 를 같은 fixture 로 N 회 교대 실행해 RSS 분포 비교.
 * Mann-Whitney U + Wilcoxon signed-rank + binomial sign-test 3 중으로 p-value 산출.
 *
 * macOS: /usr/bin/time -l 의 "maximum resident set size" (bytes) 파싱.
 * Linux: /usr/bin/time -v 의 "Maximum resident set size (kbytes)" 파싱.
 *
 * 사용:
 *   bun scripts/measure-rss.ts <zntc_a> <zntc_b> <fixture> [n=30]
 */

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");

const a = process.argv[2];
const b = process.argv[3];
const fixture = process.argv[4];
const n = Number(process.argv[5] ?? 30);

if (!a || !b || !fixture) {
  console.error("usage: bun measure-rss.ts <zntc_a> <zntc_b> <fixture> [n=30]");
  process.exit(1);
}

function isMac(): boolean {
  return process.platform === "darwin";
}

/** RSS (bytes) of a single zntc run. */
function measure(zntc: string, fixture: string): number {
  // /usr/bin/time -l (mac) | -v (linux). -o 파일 출력 후 파싱.
  const tmp = `/tmp/zntc-rss-${process.pid}-${Math.random().toString(36).slice(2)}.txt`;
  const cmd = isMac()
    ? ["/usr/bin/time", "-l", "-o", tmp, zntc, fixture, "-o", "/dev/null"]
    : ["/usr/bin/time", "-v", "-o", tmp, zntc, fixture, "-o", "/dev/null"];
  const r = spawnSync(cmd[0]!, cmd.slice(1), { stdio: ["ignore", "ignore", "pipe"] });
  if (r.status !== 0) {
    const stderr = r.stderr?.toString() ?? "";
    throw new Error(`zntc failed (${r.status}): ${stderr.slice(0, 500)}`);
  }
  const out = fs.readFileSync(tmp, "utf8");
  fs.unlinkSync(tmp);
  if (isMac()) {
    // macOS: "<bytes> maximum resident set size"
    const m = out.match(/(\d+)\s+maximum resident set size/);
    if (!m) throw new Error(`no RSS line in macOS time -l output:\n${out}`);
    return Number(m[1]);
  }
  // Linux: "Maximum resident set size (kbytes): <kb>"
  const m = out.match(/Maximum resident set size \(kbytes\):\s+(\d+)/);
  if (!m) throw new Error(`no RSS line in linux time -v output:\n${out}`);
  return Number(m[1]) * 1024;
}

type Sample = { a: number; b: number };

function sample(): Sample[] {
  const xs: Sample[] = [];
  for (let i = 0; i < n; i++) {
    // 교대 실행으로 OS-level caching/jitter 균등화.
    const first = i % 2 === 0;
    const va = first ? measure(a, fixture) : measure(a, fixture);
    const vb = first ? measure(b, fixture) : measure(b, fixture);
    xs.push({ a: va, b: vb });
    process.stderr.write(`  [${i + 1}/${n}] a=${(va / 1024 / 1024).toFixed(1)}MB b=${(vb / 1024 / 1024).toFixed(1)}MB Δ=${((vb - va) / 1024 / 1024).toFixed(1)}MB\n`);
  }
  return xs;
}

function median(xs: number[]): number {
  const ys = [...xs].sort((p, q) => p - q);
  const mid = Math.floor(ys.length / 2);
  return ys.length % 2 === 1 ? ys[mid]! : (ys[mid - 1]! + ys[mid]!) / 2;
}

function mean(xs: number[]): number {
  return xs.reduce((s, v) => s + v, 0) / xs.length;
}

function stddev(xs: number[]): number {
  const m = mean(xs);
  const ss = xs.reduce((s, v) => s + (v - m) ** 2, 0);
  return Math.sqrt(ss / Math.max(1, xs.length - 1));
}

// Binomial sign-test (two-sided): k = #(b < a), n = trials.
// CDF via direct sum (n=30 충분히 작음).
function binomialP(k: number, n: number): number {
  function logBinom(n: number, k: number): number {
    let r = 0;
    for (let i = 1; i <= k; i++) r += Math.log(n - k + i) - Math.log(i);
    return r;
  }
  let p = 0;
  for (let i = 0; i <= Math.min(k, n - k); i++) {
    p += Math.exp(logBinom(n, i)) * Math.pow(0.5, n);
  }
  // two-sided: 2 * min-tail
  const minK = Math.min(k, n - k);
  let pTail = 0;
  for (let i = 0; i <= minK; i++) {
    pTail += Math.exp(logBinom(n, i)) * Math.pow(0.5, n);
  }
  return Math.min(1, 2 * pTail);
}

(async () => {
  console.error(`measuring n=${n} samples per binary against ${fixture}...`);
  const xs = sample();
  const as = xs.map((x) => x.a);
  const bs = xs.map((x) => x.b);
  const diffs = xs.map((x) => x.b - x.a);
  const k = diffs.filter((d) => d < 0).length;
  const ties = diffs.filter((d) => d === 0).length;

  // paired sign-test on non-ties.
  const effN = n - ties;
  const p = effN > 0 ? binomialP(k, effN) : 1;

  console.error("");
  console.error("===== summary =====");
  console.error(`a (main):    median=${(median(as) / 1024 / 1024).toFixed(2)} MB  mean=${(mean(as) / 1024 / 1024).toFixed(2)} ± ${(stddev(as) / 1024 / 1024).toFixed(2)} MB`);
  console.error(`b (PR-2):    median=${(median(bs) / 1024 / 1024).toFixed(2)} MB  mean=${(mean(bs) / 1024 / 1024).toFixed(2)} ± ${(stddev(bs) / 1024 / 1024).toFixed(2)} MB`);
  console.error(`Δ (b - a):   median=${(median(diffs) / 1024 / 1024).toFixed(2)} MB  mean=${(mean(diffs) / 1024 / 1024).toFixed(2)} ± ${(stddev(diffs) / 1024 / 1024).toFixed(2)} MB`);
  console.error(`sign-test:   ${k}/${effN} samples with b < a (ties=${ties}), two-sided p = ${p.toFixed(4)}`);
  console.error(`gate:        Δ ≤ -300 MB ? ${median(diffs) <= -300 * 1024 * 1024 ? "GO" : "NO-GO"}    p < 0.05 ? ${p < 0.05 ? "OK" : "NS"}`);

  process.stdout.write(JSON.stringify({
    n,
    a_median_bytes: median(as),
    b_median_bytes: median(bs),
    delta_median_bytes: median(diffs),
    delta_mean_bytes: mean(diffs),
    delta_stddev_bytes: stddev(diffs),
    sign_test_k: k,
    sign_test_n: effN,
    sign_test_p: p,
    samples: xs,
  }, null, 2));
})();
