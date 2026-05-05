import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { buildRnDevServerOptions } from './options.ts';
import { serveRn } from './serve.ts';

let dir: string;
let entryPath: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zts-rn-serve-'));
  mkdirSync(join(dir, 'src'), { recursive: true });
  entryPath = join(dir, 'src/index.ts');
  writeFileSync(entryPath, 'console.log("hi");\n');
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe('serveRn — lifecycle', () => {
  test('serveRn 시작 시 initial platform spawn + initial build 대기', async () => {
    const options = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: 'ios', dev: true },
      port: 0,
      terminalActions: false,
    });
    const handle = await serveRn(options, { silent: true });
    try {
      // initial platform 이 등록되었고 first build 완료 (bundle 또는 buildError 둘 중 하나).
      expect(handle.platforms.platforms.size).toBe(1);
      const state = handle.platforms.platforms.get('ios')!;
      expect(state.bundle !== null || state.buildError !== null).toBe(true);
    } finally {
      await handle.stop();
    }
  });

  test('hmr.enabled=false → hmrBridge undefined', async () => {
    const options = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: 'ios', dev: true },
      port: 0,
      hmr: false,
      terminalActions: false,
    });
    const handle = await serveRn(options, { silent: true });
    try {
      expect(handle.hmrBridge).toBeUndefined();
    } finally {
      await handle.stop();
    }
  });

  test('hmr.enabled=true → hmrBridge 존재 + path=/hot', async () => {
    const options = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: 'ios', dev: true },
      port: 0,
      hmr: true,
      terminalActions: false,
    });
    const handle = await serveRn(options, { silent: true });
    try {
      expect(handle.hmrBridge?.path).toBe('/hot');
    } finally {
      await handle.stop();
    }
  });

  test('stop() — listener 제거 + watch handles stop', async () => {
    const options = buildRnDevServerOptions({
      bundle: { entry: entryPath, projectRoot: dir, rnPlatform: 'ios', dev: true },
      port: 0,
      terminalActions: false,
    });
    const handle = await serveRn(options, { silent: true });
    expect(handle.platforms.platforms.size).toBe(1);
    await handle.stop();
    expect(handle.platforms.platforms.size).toBe(0);
  });
});
