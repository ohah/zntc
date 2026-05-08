import { buildSync, expect, join, mkdtempSync, rmSync, tmpdir, writeFileSync } from '../helpers';

export function buildReactRefreshCode(source: string): string {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
  try {
    writeFileSync(join(dir, 'entry.ts'), source);
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    return result.outputFiles[0].text;
  } finally {
    rmSync(dir, { recursive: true });
  }
}
