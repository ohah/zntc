import { describe, test, expect } from '../helpers';
import { loadBuildRnDevServerInput } from './helpers';

describe('buildRnDevServerInput — server config 추출 (#2605)', () => {
  test('config.server.port + host → port/host 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { server: { port: 9000, host: '0.0.0.0' } },
    );
    expect(input?.port).toBe(9000);
    expect(input?.host).toBe('0.0.0.0');
  });

  test('config.projectRoot > config.root → bundle.projectRoot 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { root: '/root-from-zntc', projectRoot: '/metro-project-root' },
    );
    expect(input?.bundle.projectRoot).toBe('/metro-project-root');
  });

  test('CLI port/host > config.server', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'], port: 7777, host: '1.1.1.1' },
      { server: { port: 9000, host: '0.0.0.0' } },
    );
    expect(input?.port).toBe(7777);
    expect(input?.host).toBe('1.1.1.1');
  });

  test('config.symbolicator.customizeFrame → symbolicator 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const fn = async () => ({ collapse: true });
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { symbolicator: { customizeFrame: fn } },
    );
    expect(input?.symbolicator?.customizeFrame).toBe(fn);
  });

  test('config.symbolicator.customizeFrame 없음 → symbolicator undefined', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput({ entryPoints: ['i.js'] }, {});
    expect(input?.symbolicator).toBeUndefined();
  });

  test('config.server.enhanceMiddleware/rewriteRequestUrl 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const enhance = (mw: unknown) => mw;
    const rewrite = (u: string) => u;
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { server: { enhanceMiddleware: enhance, rewriteRequestUrl: rewrite } },
    );
    expect(input?.enhanceMiddleware).toBe(enhance);
    expect(input?.rewriteRequestUrl).toBe(rewrite);
  });

  test('config.server.useGlobalHotkey=false → terminalActions=false', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { server: { useGlobalHotkey: false } },
    );
    expect(input?.terminalActions).toBe(false);
  });

  test('config.server.useGlobalHotkey=true (or 미지정) → terminalActions 미설정 (default true)', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const a = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { server: { useGlobalHotkey: true } },
    );
    expect(a?.terminalActions).toBeUndefined();
    const b = buildRnDevServerInput({ entryPoints: ['i.js'] }, {});
    expect(b?.terminalActions).toBeUndefined();
  });

  test('CLI --no-interactive → terminalActions=false (config.useGlobalHotkey 보다 우선, #2605 audit)', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const a = buildRnDevServerInput({ entryPoints: ['i.js'], noInteractive: true }, {});
    expect(a?.terminalActions).toBe(false);

    const b = buildRnDevServerInput(
      { entryPoints: ['i.js'], noInteractive: true },
      { server: { useGlobalHotkey: true } },
    );
    expect(b?.terminalActions).toBe(false);
  });

  test('config.server.forwardClientLogs / hmr → dev server input 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { server: { forwardClientLogs: true, hmr: false } },
    );
    expect(input?.bundle.extra?.forwardClientLogs).toBe(true);
    expect(input?.hmr).toBe(false);
  });
});
