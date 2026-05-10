import {
  buildSync,
  expect,
  join,
  mkdtempSync,
  rmSync,
  tmpdir,
  transpile,
  writeFileSync,
} from '../helpers';

type TranspileOptions = NonNullable<Parameters<typeof transpile>[1]>;

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

export function transpileReactRefreshCode(source: string, options: TranspileOptions = {}): string {
  const result = transpile(source, { filename: 'entry.tsx', jsx: 'automatic', ...options });
  expect(result.errors).toBeUndefined();
  return result.code;
}
