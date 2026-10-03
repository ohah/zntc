import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildSync, init } from '../packages/core/dist/index.js';

// Preserve the fresh-addon/self-hosting probe previously in setup-zntc.
await init();
const dir = mkdtempSync(join(tmpdir(), 'zntc-ci-napi-'));
try {
  const entry = join(dir, 'index.ts');
  const outfile = join(dir, 'out.js');
  writeFileSync(
    entry,
    'import styled from "styled-components"; const Button = styled.button\u0060color:red;\u0060; console.log(typeof Button);',
  );
  buildSync({
    entryPoints: [entry],
    bundle: true,
    outfile,
    external: ['styled-components'],
    compiler: { styledComponents: { namespace: 'ci' } },
  });
  if (!readFileSync(outfile, 'utf8').includes('ci__sc-')) {
    throw new Error('fresh NAPI sanity check failed: styledComponents.namespace was not applied');
  }
} finally {
  rmSync(dir, { recursive: true, force: true });
}
