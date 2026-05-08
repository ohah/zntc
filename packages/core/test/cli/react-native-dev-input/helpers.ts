export async function loadBuildRnDevServerInput() {
  const { buildRnDevServerInput } = await import('../../../bin/rn-dev-input.mjs');
  return buildRnDevServerInput;
}

export function captureStderr<T>(callback: () => T): { result: T; output: string } {
  const original = process.stderr.write.bind(process.stderr);
  const writes: string[] = [];

  // @ts-expect-error — runtime mock
  process.stderr.write = (chunk: string | Uint8Array) => {
    writes.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf-8'));
    return true;
  };

  try {
    return { result: callback(), output: writes.join('') };
  } finally {
    process.stderr.write = original;
  }
}
