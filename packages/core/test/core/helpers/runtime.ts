import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export async function runBundleStdout(code: string): Promise<string> {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-run-'));
  const out = join(dir, 'out.mjs');
  writeFileSync(out, code);
  const captured: string[] = [];
  const orig = console.log;
  console.log = (...args: unknown[]) => {
    captured.push(args.map((a) => String(a)).join(' '));
  };
  try {
    await import(out);
  } finally {
    console.log = orig;
    rmSync(dir, { recursive: true });
  }
  return captured.join('\n');
}
