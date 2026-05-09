import { describe, expect, test } from 'bun:test';

import zntcLoader, { type ZntcLoaderOptions } from '../src/index.ts';

interface CallbackResult {
  err: Error | null;
  content?: string;
  map?: object | string;
}

type LoaderThis = ThisParameterType<typeof zntcLoader>;
interface MockContext extends LoaderThis {
  result: Promise<CallbackResult>;
}

function createContext(resourcePath: string, options: ZntcLoaderOptions = {}): MockContext {
  let resolve!: (r: CallbackResult) => void;
  const result = new Promise<CallbackResult>((r) => {
    resolve = r;
  });
  return {
    resourcePath,
    result,
    async() {
      return (err, content, map) => {
        resolve({ err, content, map });
      };
    },
    getOptions() {
      return options;
    },
  };
}

async function run(
  source: string,
  resourcePath: string,
  options: ZntcLoaderOptions = {},
): Promise<CallbackResult> {
  const ctx = createContext(resourcePath, options);
  zntcLoader.call(ctx, source);
  return ctx.result;
}

describe('@zntc/rspack-loader', () => {
  test('TS → JS — basic transpile', async () => {
    const { err, content } = await run('const x: number = 1;\nexport default x;', '/virtual/a.ts');
    expect(err).toBeNull();
    expect(content).toBeString();
    expect(content).not.toContain(': number');
    expect(content).toContain('export default');
  });

  test('TSX → JS — JSX 변환', async () => {
    const { err, content } = await run(
      'const C = () => <div>hi</div>;\nexport default C;',
      '/virtual/a.tsx',
      { transpileOptions: { jsx: 'automatic' } },
    );
    expect(err).toBeNull();
    expect(content).toBeString();
    expect(content).not.toContain('<div>');
    expect(content).toMatch(/jsx|createElement/);
  });

  test('sourcemap — JSON object 로 반환 (string 아님)', async () => {
    const { err, map } = await run('const x = 1;', '/virtual/a.ts', {
      transpileOptions: { sourcemap: true },
    });
    expect(err).toBeNull();
    expect(typeof map).toBe('object');
    expect(map).toMatchObject({ version: 3 });
  });

  test('filename — resourcePath 가 transpile 에 전달되어 진단/맵에 반영', async () => {
    const { err, map } = await run('const x = 1;', '/virtual/some-file.ts', {
      transpileOptions: { sourcemap: true },
    });
    expect(err).toBeNull();
    const sources = (map as { sources?: string[] } | undefined)?.sources ?? [];
    expect(sources.some((s) => s.includes('some-file.ts'))).toBe(true);
  });

  test('error — callback 으로 Error 전달 (throw 아님)', async () => {
    const { err, content } = await run('const x: = ;', '/virtual/bad.ts');
    expect(err).toBeInstanceOf(Error);
    expect(content).toBeUndefined();
  });

  test('tsconfigCache=false — 캐시 미생성 경로도 동작', async () => {
    const { err, content } = await run('const x: number = 1;', '/virtual/a.ts', {
      tsconfigCache: false,
    });
    expect(err).toBeNull();
    expect(content).toContain('const x = 1');
  });

  test('options 미지정 — default 동작', async () => {
    const { err, content } = await run('const x: number = 1;', '/virtual/a.ts');
    expect(err).toBeNull();
    expect(content).toContain('const x = 1');
  });
});
