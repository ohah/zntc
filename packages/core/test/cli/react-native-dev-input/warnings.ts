import { describe, test, expect } from '../helpers';
import { captureStderr, loadBuildRnDevServerInput } from './helpers';

describe('buildRnDevServerInput — unsupported field warnings (#2605)', () => {
  test('미지원 필드 (transformer.inlineRequires/minifier, serializer.bundleType, server.verifyConnections) — stderr 경고', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const { output } = captureStderr(() => {
      buildRnDevServerInput(
        { entryPoints: ['i.js'] },
        {
          transformer: { inlineRequires: true, minifier: 'terser' },
          serializer: { bundleType: 'module' },
          server: { forwardClientLogs: true, verifyConnections: true },
        },
      );
    });

    expect(output).toContain('transformer.inlineRequires');
    expect(output).toContain('transformer.minifier');
    expect(output).toContain('serializer.bundleType');
    expect(output).toContain('server.verifyConnections');
    expect(output).not.toContain('transformer.babel');
    expect(output).not.toContain('serializer.prelude');
    expect(output).not.toContain('serializer.inlineSourceMap');
    expect(output).not.toContain('server.forwardClientLogs');
  });

  test('미지원 필드 0 — stderr 경고 0 출력', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const { output } = captureStderr(() => {
      buildRnDevServerInput({ entryPoints: ['i.js'] }, { entry: 'i.js', root: '.' });
    });
    expect(output).not.toContain('[zntc:rn-dev]');
  });

  test('transformer/serializer/server 빈 객체 — stderr 경고 0', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const { output } = captureStderr(() => {
      buildRnDevServerInput(
        { entryPoints: ['i.js'] },
        { transformer: {}, serializer: {}, server: {} },
      );
    });
    expect(output).not.toContain('[zntc:rn-dev]');
  });

  test('UNSUPPORTED_FIELDS — server.unstable_serverRoot 도 경고', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const { output } = captureStderr(() => {
      buildRnDevServerInput({ entryPoints: ['i.js'] }, { server: { unstable_serverRoot: '/srv' } });
    });
    expect(output).toContain('server.unstable_serverRoot');
  });
});
