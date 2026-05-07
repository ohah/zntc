#!/usr/bin/env node

import { fileURLToPath } from 'node:url';

function isMissingBuiltCli(error) {
  if (!error || error.code !== 'ERR_MODULE_NOT_FOUND') return false;
  const builtCliPath = fileURLToPath(new URL('../dist/cli.js', import.meta.url));
  return String(error.message ?? '').includes(builtCliPath);
}

try {
  await import('../dist/cli.js');
} catch (error) {
  if (!isMissingBuiltCli(error)) throw error;
  console.error('error: @zntc/init JS bundle is missing');
  console.error('');
  console.error('note: zntc-init runs the built JS entry at packages/init/dist/cli.js.');
  console.error('note: source TypeScript is not loaded directly by Node.');
  console.error('');
  console.error('help: run `bun run --cwd packages/init build` from the repository root.');
  process.exit(1);
}
