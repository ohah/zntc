import { expect } from 'bun:test';

export function diagText(diag: unknown): string {
  if (diag && typeof diag === 'object') {
    const d = diag as { text?: unknown; message?: unknown };
    if (typeof d.text === 'string') return d.text;
    if (typeof d.message === 'string') return d.message;
  }
  return String(diag);
}

export function expectPluginDiagnostic(
  result: { errors: unknown[] },
  expected: {
    plugin: string;
    hook: string;
    message: string;
    fileIncludes?: string;
    textIncludes?: string;
  },
) {
  const diag = result.errors.find((entry) => {
    const d = entry as { code?: string };
    const text = diagText(entry);
    return (
      d.code === 'plugin_error' &&
      text.includes(expected.plugin) &&
      text.includes(expected.hook) &&
      text.includes(expected.message)
    );
  }) as ({ location?: { file?: string }; code?: string } & Record<string, unknown>) | undefined;

  expect(diag, `missing plugin_error diagnostic in ${JSON.stringify(result.errors)}`).toBeDefined();
  if (expected.fileIncludes) {
    expect(diag?.location?.file ?? '').toContain(expected.fileIncludes);
  }
  if (expected.textIncludes) {
    expect(diagText(diag)).toContain(expected.textIncludes);
  }
}
