import { describe, test, expect } from './helpers';

describe('buildRnDevServerInput — config + opts 추출 (#2605)', () => {
  test('entry 없음 → null', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    expect(buildRnDevServerInput({ entryPoints: [] }, {})).toBeNull();
    expect(buildRnDevServerInput({}, {})).toBeNull();
  });

  test('config.entry 만 있어도 entry 채워짐', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput({}, { entry: 'src/index.ts' });
    expect(input?.bundle.entry).toBe('src/index.ts');
  });

  test('CLI flag 우선 — config.entry override', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput({ entryPoints: ['cli.js'] }, { entry: 'config.js' });
    expect(input?.bundle.entry).toBe('cli.js');
  });

  test('config.server.port + host → port/host 매핑', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { server: { port: 9000, host: '0.0.0.0' } },
    );
    expect(input?.port).toBe(9000);
    expect(input?.host).toBe('0.0.0.0');
  });

  test('CLI port/host > config.server', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'], port: 7777, host: '1.1.1.1' },
      { server: { port: 9000, host: '0.0.0.0' } },
    );
    expect(input?.port).toBe(7777);
    expect(input?.host).toBe('1.1.1.1');
  });

  test('config.resolver.* → bundle.extra + nodeModulesPaths 매핑', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      {
        resolver: {
          nodeModulesPaths: ['../../node_modules'],
          blockList: [/.web.tsx?$/],
          extraNodeModules: { foo: '/x' },
          sourceExts: ['.ts'],
          assetExts: ['.png'],
        },
      },
    );
    expect(input?.nodeModulesPaths).toEqual(['../../node_modules']);
    expect(input?.bundle.extra?.blockList).toEqual([/.web.tsx?$/]);
    expect(input?.bundle.extra?.fallback).toEqual({ foo: '/x' });
    expect(input?.bundle.extra?.sourceExts).toEqual(['.ts']);
    expect(input?.bundle.extra?.assetExts).toEqual(['.png']);
  });

  test('config.symbolicator.customizeFrame → symbolicator 매핑', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const fn = async () => ({ collapse: true });
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { symbolicator: { customizeFrame: fn } },
    );
    expect(input?.symbolicator?.customizeFrame).toBe(fn);
  });

  test('config.symbolicator.customizeFrame 없음 → symbolicator undefined', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput({ entryPoints: ['i.js'] }, {});
    expect(input?.symbolicator).toBeUndefined();
  });

  test('config.server.enhanceMiddleware/rewriteRequestUrl 매핑', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const enhance = (mw: unknown) => mw;
    const rewrite = (u: string) => u;
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { server: { enhanceMiddleware: enhance, rewriteRequestUrl: rewrite } },
    );
    expect(input?.enhanceMiddleware).toBe(enhance);
    expect(input?.rewriteRequestUrl).toBe(rewrite);
  });

  test('config.watchFolders → bundle.extra.watchFolders', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { watchFolders: ['../shared', '../tokens'] },
    );
    expect(input?.bundle.extra?.watchFolders).toEqual(['../shared', '../tokens']);
  });

  test('config.alias / moduleSpecifierMap → bundle.override 매핑', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      {
        alias: { '~': '/abs/src' },
        moduleSpecifierMap: { lodash: 'lodash/{name}' },
      },
    );
    expect(input?.bundle.override?.alias).toEqual({ '~': '/abs/src' });
    expect(input?.bundle.override?.moduleSpecifierMap).toEqual({ lodash: 'lodash/{name}' });
  });

  test('config.transformer.babelTransformerPath 매핑', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { transformer: { babelTransformerPath: 'react-native-svg-transformer' } },
    );
    expect(input?.bundle.extra?.babelTransformerPath).toBe('react-native-svg-transformer');
  });

  test('config.dev=false → bundle.dev=false (CLI override 가능)', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const a = buildRnDevServerInput({ entryPoints: ['i.js'] }, { dev: false });
    expect(a?.bundle.dev).toBe(false);

    // CLI --no-dev (devMode=false) 도 false.
    const b = buildRnDevServerInput({ entryPoints: ['i.js'], devMode: false }, { dev: true });
    expect(b?.bundle.dev).toBe(false);
  });

  test('config.minify → bundle.minify', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput({ entryPoints: ['i.js'] }, { minify: true });
    expect(input?.bundle.minify).toBe(true);
  });

  test('config.root → projectRoot (resolve 적용)', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput({ entryPoints: ['i.js'] }, { root: '/abs/path' });
    expect(input?.bundle.projectRoot).toBe('/abs/path');
  });

  test('rnPlatform=android override', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput({ entryPoints: ['i.js'], rnPlatform: 'android' }, {});
    expect(input?.bundle.rnPlatform).toBe('android');
  });

  test('config.serializer.polyfills → bundle.extra.polyfills 매핑', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { serializer: { polyfills: ['./shims/myPolyfill.js'] } },
    );
    expect(input?.bundle.extra?.polyfills).toEqual(['./shims/myPolyfill.js']);
  });

  test('config.serializer.extraVars → bundle.extra.extraVars 매핑', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { serializer: { extraVars: { __APP_VERSION__: '1.0.0', __FLAG__: true } } },
    );
    expect(input?.bundle.extra?.extraVars).toEqual({
      __APP_VERSION__: '1.0.0',
      __FLAG__: true,
    });
  });

  test('config.server.useGlobalHotkey=false → terminalActions=false', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { server: { useGlobalHotkey: false } },
    );
    expect(input?.terminalActions).toBe(false);
  });

  test('config.server.useGlobalHotkey=true (or 미지정) → terminalActions 미설정 (default true)', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const a = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { server: { useGlobalHotkey: true } },
    );
    expect(a?.terminalActions).toBeUndefined();
    const b = buildRnDevServerInput({ entryPoints: ['i.js'] }, {});
    expect(b?.terminalActions).toBeUndefined();
  });

  test('CLI --no-interactive → terminalActions=false (config.useGlobalHotkey 보다 우선, #2605 audit)', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    // CLI flag 가 명시적 disable.
    const a = buildRnDevServerInput({ entryPoints: ['i.js'], noInteractive: true }, {});
    expect(a?.terminalActions).toBe(false);
    // CLI flag 가 config 보다 우선 — useGlobalHotkey:true 라도 noInteractive 가 우선.
    const b = buildRnDevServerInput(
      { entryPoints: ['i.js'], noInteractive: true },
      { server: { useGlobalHotkey: true } },
    );
    expect(b?.terminalActions).toBe(false);
  });

  test('미지원 필드 (transformer.inlineRequires/minifier, serializer.bundleType, server.verifyConnections) — stderr 경고', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const original = process.stderr.write.bind(process.stderr);
    const writes: string[] = [];
    // @ts-expect-error — runtime mock
    process.stderr.write = (chunk: string | Uint8Array) => {
      writes.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf-8'));
      return true;
    };
    try {
      buildRnDevServerInput(
        { entryPoints: ['i.js'] },
        {
          transformer: { inlineRequires: true, minifier: 'terser' },
          serializer: { bundleType: 'module' },
          server: { forwardClientLogs: true, verifyConnections: true },
        },
      );
    } finally {
      process.stderr.write = original;
    }
    const all = writes.join('');
    expect(all).toContain('transformer.inlineRequires');
    expect(all).toContain('transformer.minifier');
    expect(all).toContain('serializer.bundleType');
    expect(all).toContain('server.verifyConnections');
    // transformer.babel / serializer.prelude / serializer.inlineSourceMap 는
    // 매핑 가능해서 경고 없음.
    expect(all).not.toContain('transformer.babel');
    expect(all).not.toContain('serializer.prelude');
    expect(all).not.toContain('serializer.inlineSourceMap');
    expect(all).not.toContain('server.forwardClientLogs');
  });

  test('config.server.forwardClientLogs / hmr → dev server input 매핑', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { server: { forwardClientLogs: true, hmr: false } },
    );
    expect(input?.bundle.extra?.forwardClientLogs).toBe(true);
    expect(input?.hmr).toBe(false);
  });

  test('미지원 필드 0 — stderr 경고 0 출력', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const original = process.stderr.write.bind(process.stderr);
    const writes: string[] = [];
    // @ts-expect-error — runtime mock
    process.stderr.write = (chunk: string | Uint8Array) => {
      writes.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf-8'));
      return true;
    };
    try {
      buildRnDevServerInput({ entryPoints: ['i.js'] }, { entry: 'i.js', root: '.' });
    } finally {
      process.stderr.write = original;
    }
    expect(writes.join('')).not.toContain('[zntc:rn-dev]');
  });

  test('transformer/serializer/server 빈 객체 — stderr 경고 0', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const original = process.stderr.write.bind(process.stderr);
    const writes: string[] = [];
    // @ts-expect-error — runtime mock
    process.stderr.write = (chunk: string | Uint8Array) => {
      writes.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf-8'));
      return true;
    };
    try {
      buildRnDevServerInput(
        { entryPoints: ['i.js'] },
        { transformer: {}, serializer: {}, server: {} },
      );
    } finally {
      process.stderr.write = original;
    }
    expect(writes.join('')).not.toContain('[zntc:rn-dev]');
  });

  test('UNSUPPORTED_FIELDS — server.unstable_serverRoot 도 경고', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const original = process.stderr.write.bind(process.stderr);
    const writes: string[] = [];
    // @ts-expect-error — runtime mock
    process.stderr.write = (chunk: string | Uint8Array) => {
      writes.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf-8'));
      return true;
    };
    try {
      buildRnDevServerInput({ entryPoints: ['i.js'] }, { server: { unstable_serverRoot: '/srv' } });
    } finally {
      process.stderr.write = original;
    }
    expect(writes.join('')).toContain('server.unstable_serverRoot');
  });

  test('config.serializer.prelude → bundle.extra.prelude 매핑 (warning 없음)', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const original = process.stderr.write.bind(process.stderr);
    const writes: string[] = [];
    // @ts-expect-error — runtime mock
    process.stderr.write = (chunk: string | Uint8Array) => {
      writes.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf-8'));
      return true;
    };
    let input: ReturnType<typeof buildRnDevServerInput>;
    try {
      input = buildRnDevServerInput(
        { entryPoints: ['i.js'] },
        { serializer: { prelude: ['./shims/prelude.js'] } },
      );
    } finally {
      process.stderr.write = original;
    }
    expect(input?.bundle.extra?.prelude).toEqual(['./shims/prelude.js']);
    expect(writes.join('')).not.toContain('serializer.prelude');
  });

  test('config.transformer.babel → bundle.extra.babel 매핑 (warning 없음)', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const original = process.stderr.write.bind(process.stderr);
    const writes: string[] = [];
    // @ts-expect-error — runtime mock
    process.stderr.write = (chunk: string | Uint8Array) => {
      writes.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf-8'));
      return true;
    };
    const inlineBabel = {
      presets: ['@ohah/react-native-mcp-server/babel-preset'],
      plugins: [['@babel/plugin-proposal-decorators', { legacy: true }] as [string, object]],
    };
    let input: ReturnType<typeof buildRnDevServerInput>;
    try {
      input = buildRnDevServerInput(
        { entryPoints: ['i.js'] },
        { transformer: { babel: inlineBabel } },
      );
    } finally {
      process.stderr.write = original;
    }
    expect(input?.bundle.extra?.babel).toEqual(inlineBabel);
    expect(writes.join('')).not.toContain('transformer.babel');
  });

  test('config.serializer.inlineSourceMap → bundle.extra.inlineSourceMap 매핑 (warning 없음, #2605 audit P1)', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const original = process.stderr.write.bind(process.stderr);
    const writes: string[] = [];
    // @ts-expect-error — runtime mock
    process.stderr.write = (chunk: string | Uint8Array) => {
      writes.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf-8'));
      return true;
    };
    let input: ReturnType<typeof buildRnDevServerInput>;
    try {
      input = buildRnDevServerInput(
        { entryPoints: ['i.js'] },
        { serializer: { inlineSourceMap: true } },
      );
    } finally {
      process.stderr.write = original;
    }
    expect(input?.bundle.extra?.inlineSourceMap).toBe(true);
    expect(writes.join('')).not.toContain('serializer.inlineSourceMap');
  });

  test('config.sourcemapSourcesRoot → bundle.extra.sourceRoot 매핑 (Metro 호환)', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { sourcemapSourcesRoot: '/abs/proj' },
    );
    expect(input?.bundle.extra?.sourceRoot).toBe('/abs/proj');
  });

  test('config.server.silentConsoleErrorPatterns → bundle.extra.silentConsoleErrorPatterns 매핑 (Metro 호환, withExpo)', async () => {
    const { buildRnDevServerInput } = await import('../../bin/rn-dev-input.mjs');
    const original = process.stderr.write.bind(process.stderr);
    const writes: string[] = [];
    // @ts-expect-error — runtime mock
    process.stderr.write = (chunk: string | Uint8Array) => {
      writes.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf-8'));
      return true;
    };
    let input: ReturnType<typeof buildRnDevServerInput>;
    try {
      input = buildRnDevServerInput(
        { entryPoints: ['i.js'] },
        {
          server: {
            silentConsoleErrorPatterns: [
              '^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$',
            ],
          },
        },
      );
    } finally {
      process.stderr.write = original;
    }
    expect(input?.bundle.extra?.silentConsoleErrorPatterns).toEqual([
      '^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$',
    ]);
    // 매핑 가능한 필드라 unsupported 경고 없음.
    expect(writes.join('')).not.toContain('server.silentConsoleErrorPatterns');
  });
});
