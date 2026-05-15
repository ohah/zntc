import { describe, test, expect, afterEach } from 'bun:test';
import { createFixture, runNode, runZntc, runZntcInDir } from './helpers';
import { join, basename } from 'node:path';
import { readFileSync, readdirSync, realpathSync, symlinkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

/// CJS/Node 프리셋으로 번들하고 outFile 경로 반환. 번들 실패 시 throw.
async function bundleCjsNode(dir: string, entry: string, outName = 'out.cjs'): Promise<string> {
  const outFile = join(dir, outName);
  const bundle = await runZntc([
    '--bundle',
    join(dir, entry),
    '--format=cjs',
    '--platform=node',
    '-o',
    outFile,
  ]);
  if (bundle.exitCode !== 0) {
    throw new Error(`zntc bundle failed: ${bundle.stderr}`);
  }
  return outFile;
}

describe('Node.js 호환 edge case', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  describe('import.meta.* (ESM → CJS 치환)', () => {
    test('import.meta.url → pathToFileURL(__filename).href', async () => {
      const f = await createFixture({ 'app.ts': `console.log(import.meta.url);` });
      cleanup = f.cleanup;

      const outFile = await bundleCjsNode(f.dir, 'app.ts');
      const run = await runNode(outFile);

      // Node가 실제로 실행한 결과: file:// URL이어야 함
      expect(run.stdout).toMatch(/^file:\/\//);
      expect(run.stdout).toContain(basename(outFile));
    });

    test('import.meta.dirname → __dirname (Node는 realpath 기준)', async () => {
      const f = await createFixture({ 'app.ts': `console.log(import.meta.dirname);` });
      cleanup = f.cleanup;

      const outFile = await bundleCjsNode(f.dir, 'app.ts');
      const run = await runNode(outFile);

      expect(run.stdout).toBe(realpathSync(f.dir));
    });

    test('import.meta.filename → __filename', async () => {
      const f = await createFixture({ 'app.ts': `console.log(import.meta.filename);` });
      cleanup = f.cleanup;

      const outFile = await bundleCjsNode(f.dir, 'app.ts');
      const run = await runNode(outFile);

      expect(run.stdout).toBe(realpathSync(outFile));
    });
  });

  describe('심볼릭 링크 (entry)', () => {
    test('symlink를 통해 entry를 번들해도 실행 결과가 동일하다', async () => {
      const f = await createFixture({
        'real/app.ts': `console.log("hello", typeof import.meta.url);`,
      });
      cleanup = f.cleanup;

      // fixture는 매번 새 temp dir이라 존재 체크 불필요
      const linkEntry = join(f.dir, 'link-app.ts');
      symlinkSync(join(f.dir, 'real/app.ts'), linkEntry);

      const outFile = join(f.dir, 'out.cjs');
      const bundle = await runZntc([
        '--bundle',
        linkEntry,
        '--format=cjs',
        '--platform=node',
        '-o',
        outFile,
      ]);
      if (bundle.exitCode !== 0) throw new Error(`zntc bundle failed: ${bundle.stderr}`);

      const run = await runNode(outFile);
      expect(run.stdout).toBe('hello string');
    });

    // ─── #2154 preserveSymlinks 동작 검증 ───────────────────────────────────
    // pnpm 식 fixture: node_modules/.store/foo@1/node_modules/foo/index.js (real)
    //                  node_modules/foo → 위로 symlink.
    // - preserveSymlinks=false (default): symlink 를 realpath 로 따라가 .store 경로로 resolve.
    // - preserveSymlinks=true: symlink path 그대로 유지 → node_modules/foo/index.js 경로.
    // 검증은 metafile 의 input 경로로 확인.

    test('preserveSymlinks 미지정 (default false): pnpm-style symlink 가 realpath 로 resolve', async () => {
      const f = await createFixture({
        'entry.ts': `import {x} from 'foo';\nconsole.log(x);`,
        'node_modules/.store/foo@1/node_modules/foo/package.json': `{"name":"foo","main":"index.js"}`,
        'node_modules/.store/foo@1/node_modules/foo/index.js': `export const x = "PNPM_REALPATH_VALUE";`,
      });
      cleanup = f.cleanup;
      symlinkSync(
        join(f.dir, 'node_modules/.store/foo@1/node_modules/foo'),
        join(f.dir, 'node_modules/foo'),
      );

      const outFile = join(f.dir, 'out.js');
      const bundle = await runZntcInDir(f.dir, [
        '--bundle',
        join(f.dir, 'entry.ts'),
        '--format=esm',
        '-o',
        outFile,
        '--metafile=meta.json',
      ]);
      if (bundle.exitCode !== 0) throw new Error(`zntc bundle failed: ${bundle.stderr}`);

      const meta = JSON.parse(readFileSync(join(f.dir, 'meta.json'), 'utf8'));
      const inputs = Object.keys(meta.inputs);
      // realpath → .store 경로가 input 으로 등장.
      expect(inputs.some((p) => p.includes('/.store/foo@1/'))).toBe(true);
    });

    test('preserveSymlinks=true: pnpm-style symlink 가 link path 그대로 유지', async () => {
      const f = await createFixture({
        'entry.ts': `import {x} from 'foo';\nconsole.log(x);`,
        'node_modules/.store/foo@1/node_modules/foo/package.json': `{"name":"foo","main":"index.js"}`,
        'node_modules/.store/foo@1/node_modules/foo/index.js': `export const x = "PNPM_LINK_VALUE";`,
      });
      cleanup = f.cleanup;
      symlinkSync(
        join(f.dir, 'node_modules/.store/foo@1/node_modules/foo'),
        join(f.dir, 'node_modules/foo'),
      );

      const outFile = join(f.dir, 'out.js');
      const bundle = await runZntcInDir(f.dir, [
        '--bundle',
        join(f.dir, 'entry.ts'),
        '--format=esm',
        '-o',
        outFile,
        '--metafile=meta.json',
        '--preserve-symlinks',
      ]);
      if (bundle.exitCode !== 0) throw new Error(`zntc bundle failed: ${bundle.stderr}`);

      const meta = JSON.parse(readFileSync(join(f.dir, 'meta.json'), 'utf8'));
      const inputs = Object.keys(meta.inputs);
      // realpath 로 안 따라감 → .store 경로 미등장 + link path (.store 미포함) 등장.
      expect(inputs.some((p) => p.includes('/.store/foo@1/'))).toBe(false);
      expect(
        inputs.some((p) => p.endsWith('/node_modules/foo/index.js') && !p.includes('/.store/')),
      ).toBe(true);
    });
  });

  describe('상대 경로 entry', () => {
    test('cwd 기준 상대 경로로 번들해도 동작한다', async () => {
      const f = await createFixture({ 'sub/app.ts': `console.log("rel ok");` });
      cleanup = f.cleanup;

      const outFile = join(f.dir, 'out.cjs');
      const bundle = await runZntcInDir(f.dir, [
        '--bundle',
        './sub/app.ts',
        '--format=cjs',
        '--platform=node',
        '-o',
        outFile,
      ]);
      if (bundle.exitCode !== 0) throw new Error(`zntc bundle failed: ${bundle.stderr}`);

      const run = await runNode(outFile);
      expect(run.stdout).toBe('rel ok');
    });
  });

  describe('ESM 출력', () => {
    test('ESM 출력에서 import.meta.url은 변환하지 않고 Node가 제공', async () => {
      const f = await createFixture({
        'app.ts': `console.log(import.meta.url);`,
        'package.json': `{"type": "module"}`,
      });
      cleanup = f.cleanup;

      const outFile = join(f.dir, 'out.mjs');
      const bundle = await runZntc([
        '--bundle',
        join(f.dir, 'app.ts'),
        '--format=esm',
        '--platform=node',
        '-o',
        outFile,
      ]);
      if (bundle.exitCode !== 0) throw new Error(`zntc bundle failed: ${bundle.stderr}`);

      const run = await runNode(outFile);
      expect(run.stdout).toMatch(/^file:\/\//);
      expect(run.stdout).toContain(basename(outFile));
    });
  });

  describe('ESM+CJS interop (#1456)', () => {
    test('shim injected for platform=node + CJS wrap', async () => {
      const f = await createFixture({
        'app.ts': `import dep from 'cjs-dep';\nconsole.log(dep.hostname);`,
        'package.json': `{"type": "module"}`,
        'node_modules/cjs-dep/package.json': `{"name":"cjs-dep","main":"index.cjs"}`,
        'node_modules/cjs-dep/index.cjs': `const os = require('os');\nmodule.exports = { hostname: os.hostname() };`,
      });
      cleanup = f.cleanup;
      const outFile = join(f.dir, 'out.mjs');
      const bundle = await runZntc([
        '--bundle',
        join(f.dir, 'app.ts'),
        '--format=esm',
        '--platform=node',
        '-o',
        outFile,
      ]);
      if (bundle.exitCode !== 0) throw new Error(`zntc bundle failed: ${bundle.stderr}`);
      const bundled = readFileSync(outFile, 'utf8');
      expect(bundled).toContain('import { createRequire } from "node:module"');
      const run = await runNode(outFile);
      expect(run.stdout.length).toBeGreaterThan(0);
    });

    test('shim NOT injected for pure ESM', async () => {
      const f = await createFixture({ 'app.ts': `export const v = 1;\nconsole.log(v);` });
      cleanup = f.cleanup;
      const outFile = join(f.dir, 'out.mjs');
      const bundle = await runZntc([
        '--bundle',
        join(f.dir, 'app.ts'),
        '--format=esm',
        '--platform=node',
        '-o',
        outFile,
      ]);
      if (bundle.exitCode !== 0) throw new Error(`zntc bundle failed: ${bundle.stderr}`);
      expect(readFileSync(outFile, 'utf8')).not.toContain('createRequire');
    });

    test('shim NOT injected for platform=browser', async () => {
      const f = await createFixture({
        'app.ts': `import dep from 'cjs-dep';\nconsole.log(dep.x);`,
        'node_modules/cjs-dep/package.json': `{"name":"cjs-dep","main":"index.cjs"}`,
        'node_modules/cjs-dep/index.cjs': `module.exports = { x: 1 };`,
      });
      cleanup = f.cleanup;
      const outFile = join(f.dir, 'out.mjs');
      const bundle = await runZntc([
        '--bundle',
        join(f.dir, 'app.ts'),
        '--format=esm',
        '--platform=browser',
        '-o',
        outFile,
      ]);
      if (bundle.exitCode !== 0) throw new Error(`zntc bundle failed: ${bundle.stderr}`);
      const bundled = readFileSync(outFile, 'utf8');
      expect(bundled).not.toContain('node:module');
      expect(bundled).not.toContain('createRequire');
    });

    test('code splitting: shim injected in chunk containing external require', async () => {
      // shim 필요 조건은 `kind=.require and is_external` 한 import_record 의 존재
      // (#cbd201f6 — `__commonJS` wrapper 자체는 cb 직접 호출이라 native require 안 씀).
      // CJS dep 의 `index.cjs` 안에서 builtin `require('node:fs')` 호출 → external
      // require → 해당 dep 이 들어간 chunk 에 `createRequire(import.meta.url)` shim emit.
      const f = await createFixture({
        'app.ts': `const lazy = import('./lazy');\nlazy.then((m) => console.log(m.run()));`,
        'lazy.ts': `import dep from 'cjs-dep';\nexport function run() { return dep.has; }`,
        'package.json': `{"type": "module"}`,
        'node_modules/cjs-dep/package.json': `{"name":"cjs-dep","main":"index.cjs"}`,
        'node_modules/cjs-dep/index.cjs': `const fs = require('node:fs');\nmodule.exports = { has: typeof fs.readFileSync };`,
      });
      cleanup = f.cleanup;

      const outDir = join(f.dir, 'dist');
      const bundle = await runZntc([
        '--bundle',
        join(f.dir, 'app.ts'),
        '--format=esm',
        '--platform=node',
        '--splitting',
        '--outdir',
        outDir,
      ]);
      if (bundle.exitCode !== 0) throw new Error(`zntc bundle failed: ${bundle.stderr}`);

      const outputs = readdirSync(outDir).filter((n) => n.endsWith('.js') || n.endsWith('.mjs'));
      const hasShim = outputs.some((n) =>
        readFileSync(join(outDir, n), 'utf8').includes('createRequire(import.meta.url)'),
      );
      expect(hasShim).toBe(true);
    });
  });

  describe('worker_threads', () => {
    test('CJS Node worker: new Worker(new URL) emits and runs worker bundle', async () => {
      const f = await createFixture({
        'app.ts': `
          import { Worker } from "node:worker_threads";
          import { writeFileSync } from "node:fs";

          const worker = new Worker(new URL("./worker.ts", import.meta.url));
          worker.on("message", (value) => {
            console.log("worker:" + value);
            writeFileSync(new URL("./worker-result.txt", import.meta.url), String(value));
          });
          worker.on("error", (err) => {
            console.error(err && err.stack ? err.stack : err);
            process.exitCode = 1;
          });
          worker.on("exit", (code) => {
            if (code !== 0) process.exitCode = code;
          });
          worker.postMessage(20);
        `,
        'worker.ts': `
          import { parentPort } from "node:worker_threads";

          parentPort!.on("message", (value) => {
            parentPort!.postMessage(value + 22);
            parentPort!.close();
          });
        `,
      });
      cleanup = f.cleanup;

      const outFile = await bundleCjsNode(f.dir, 'app.ts');
      const out = readFileSync(outFile, 'utf8');
      expect(out).toContain('new Worker(new URL("./worker-');
      // import.meta.url polyfill 은 codegen 의 IMPORT_META_URL_NODE 와 동일 specifier (`url`).
      expect(out).toContain('require("url").pathToFileURL(__filename).href');
      expect(out).not.toContain('./worker.ts');

      const workerFile = readdirSync(f.dir).find((name) => /^worker-[a-f0-9]{8}\.cjs$/.test(name));
      expect(workerFile).toBeDefined();
      const workerOut = readFileSync(join(f.dir, workerFile!), 'utf8');
      expect(workerOut).toContain('require("node:worker_threads")');

      const run = spawnSync('node', [outFile], { encoding: 'utf8' });
      expect(run.status).toBe(0);
      expect(readFileSync(join(f.dir, 'worker-result.txt'), 'utf8')).toBe('42');
    });
  });
});
