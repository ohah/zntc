// @react-native/dev-middleware lazy load — DevTools inspector / debugger
// frontend / fusebox 등. peer optional 이라 미설치 시 graceful skip.
//
// project 기준 resolve — Rozenite 같은 monkey-patch 도구가 같은 module instance
// 를 패치할 수 있도록 (zntc 가 자기 node_modules 에서 resolve 하면 다른 instance
// 가 되어 패치 누락).

import { createRequire } from 'node:module';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { resolve } from 'node:path';
import type { Duplex } from 'node:stream';

export interface DevMiddleware {
  middleware: (req: IncomingMessage, res: ServerResponse, next: (err?: unknown) => void) => void;
  websocketEndpoints: Record<
    string,
    {
      handleUpgrade(
        req: IncomingMessage,
        socket: Duplex,
        head: Buffer,
        callback: (ws: unknown) => void,
      ): void;
      emit(event: string, ws: unknown, req: IncomingMessage): void;
    }
  >;
}

/**
 * Expo 프로젝트는 Rozenite가 @expo/cli 기준의 @react-native/dev-middleware
 * instance를 monkey-patch한다. 같은 module instance를 로드해야 RN DevTools
 * frontend URL 패치가 적용되므로 expo → @expo/cli → react-native CLI chain
 * 순서로 resolve. fallback 으로 project 직접 / zntc 자기.
 */
export function resolveDevMiddlewarePath(projectRoot: string): string | null {
  const root = resolve(projectRoot);
  const projectRequire = createRequire(`${root}/package.json`);
  const candidates: Array<() => string> = [
    () => {
      const expoPath = projectRequire.resolve('expo');
      const expoRequire = createRequire(expoPath);
      const expoCliPath = expoRequire.resolve('@expo/cli');
      const expoCliRequire = createRequire(expoCliPath);
      return expoCliRequire.resolve('@react-native/dev-middleware');
    },
    () => {
      const reactNativePath = projectRequire.resolve('react-native/package.json');
      const rnRequire = createRequire(reactNativePath);
      const cliPluginPath = rnRequire.resolve('@react-native/community-cli-plugin/package.json');
      const cliPluginRequire = createRequire(cliPluginPath);
      return cliPluginRequire.resolve('@react-native/dev-middleware');
    },
    () => projectRequire.resolve('@react-native/dev-middleware'),
    () => require.resolve('@react-native/dev-middleware'),
  ];
  for (const candidate of candidates) {
    try {
      return candidate();
    } catch {
      /* try next */
    }
  }
  return null;
}

export interface LoadDevMiddlewareOptions {
  port: number;
  projectRoot: string;
}

/**
 * `@react-native/dev-middleware` 가 설치돼있으면 DevMiddleware instance,
 * 아니면 null. errors swallow + console.warn (caller 가 dev server 띄우는 데
 * 영향 없도록).
 */
export async function loadDevMiddleware(
  options: LoadDevMiddlewareOptions,
): Promise<DevMiddleware | null> {
  const path = resolveDevMiddlewarePath(options.projectRoot);
  if (!path) return null;
  try {
    const root = resolve(options.projectRoot);
    const requireFromProject = createRequire(`${root}/package.json`);
    const mod = requireFromProject(path) as {
      createDevMiddleware: (input: {
        serverBaseUrl: string;
        projectRoot?: string;
        logger?: {
          info?: (...args: unknown[]) => void;
          warn?: (...args: unknown[]) => void;
          error?: (...args: unknown[]) => void;
        };
      }) => DevMiddleware;
    };
    return mod.createDevMiddleware({
      serverBaseUrl: `http://localhost:${options.port}`,
      projectRoot: options.projectRoot,
      logger: {
        info: () => {},
        warn: () => {},
        error: (...args) => console.error('[zntc/rn dev-middleware]', ...args),
      },
    });
  } catch {
    return null;
  }
}

export const DEV_MIDDLEWARE_PATH_PREFIXES: string[] = [
  '/json',
  '/open-debugger',
  '/debugger-frontend',
  '/launch-js-devtools',
];

/**
 * dev-middleware path prefix 의 정확 경계 매칭. `/jsonbomb` 같은 우연한
 * substring 일치를 막기 위해 정확한 path 또는 슬래시 경계 + tail 만 허용.
 * bungae Server.js 의 prefix 매칭과 동일 패턴 (#2605 audit).
 */
export function isDevMiddlewareRoute(pathname: string): boolean {
  return DEV_MIDDLEWARE_PATH_PREFIXES.some((p) => pathname === p || pathname.startsWith(`${p}/`));
}
