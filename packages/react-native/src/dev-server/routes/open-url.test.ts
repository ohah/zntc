import { describe, expect, test } from 'bun:test';
import { Readable } from 'node:stream';

import { handleOpenUrl, isOpenUrlRoute } from './open-url.ts';

describe('isOpenUrlRoute', () => {
  test('POST /open-url 매치', () => expect(isOpenUrlRoute('/open-url', 'POST')).toBe(true));
  test('GET /open-url 미매치 (POST only)', () =>
    expect(isOpenUrlRoute('/open-url', 'GET')).toBe(false));
  test('POST /other 미매치', () => expect(isOpenUrlRoute('/other', 'POST')).toBe(false));
  test('method undefined 미매치', () => expect(isOpenUrlRoute('/open-url', undefined)).toBe(false));
});

interface Recorded {
  command: string;
  args: string[];
  options: Record<string, unknown>;
}

interface MockRes {
  statusCode?: number;
  payload?: unknown;
  writeHead(c: number): void;
  end(b: string): void;
}

function makeRes(): MockRes {
  return {
    writeHead(c) {
      this.statusCode = c;
    },
    end(b) {
      this.payload = JSON.parse(b);
    },
  };
}

function streamReq(json: string) {
  const r = new Readable({ read() {} });
  r.push(json);
  r.push(null);
  return r;
}

function fakeSpawner(rec: Recorded[]) {
  return ((command: string, args: string[], options: Record<string, unknown>) => {
    rec.push({ command, args, options });
    return { unref() {} };
  }) as never;
}

describe('handleOpenUrl — happy path', () => {
  test('darwin → open <url>', async () => {
    const rec: Recorded[] = [];
    const res = makeRes();
    await handleOpenUrl(
      streamReq('{"url":"https://x.test"}') as never,
      res as never,
      fakeSpawner(rec),
      'darwin',
    );
    expect(rec).toHaveLength(1);
    expect(rec[0]).toMatchObject({ command: 'open', args: ['https://x.test'] });
    expect(res.statusCode).toBe(200);
    expect(res.payload).toEqual({ success: true });
  });

  test('win32 → rundll32 (cmd 인젝션 회피)', async () => {
    const rec: Recorded[] = [];
    await handleOpenUrl(
      streamReq('{"url":"https://w.test"}') as never,
      makeRes() as never,
      fakeSpawner(rec),
      'win32',
    );
    expect(rec[0]).toMatchObject({
      command: 'rundll32',
      args: ['url.dll,FileProtocolHandler', 'https://w.test'],
    });
  });

  test('linux → xdg-open', async () => {
    const rec: Recorded[] = [];
    await handleOpenUrl(
      streamReq('{"url":"https://l.test"}') as never,
      makeRes() as never,
      fakeSpawner(rec),
      'linux',
    );
    expect(rec[0].command).toBe('xdg-open');
  });
});

describe('handleOpenUrl — error path', () => {
  test('invalid JSON → 400 + error 응답', async () => {
    const res = makeRes();
    await handleOpenUrl(streamReq('not json') as never, res as never, fakeSpawner([]), 'linux');
    expect(res.statusCode).toBe(400);
    expect(res.payload).toEqual({ error: 'Invalid JSON body' });
  });

  test('body.url 누락 → 400', async () => {
    const res = makeRes();
    await handleOpenUrl(streamReq('{}') as never, res as never, fakeSpawner([]), 'linux');
    expect(res.statusCode).toBe(400);
    expect(res.payload).toEqual({ error: 'Invalid URL' });
  });

  test('url 이 빈 문자열 → 400', async () => {
    const res = makeRes();
    await handleOpenUrl(streamReq('{"url":""}') as never, res as never, fakeSpawner([]), 'linux');
    expect(res.statusCode).toBe(400);
  });

  test('url 이 number → 400', async () => {
    const res = makeRes();
    await handleOpenUrl(streamReq('{"url":42}') as never, res as never, fakeSpawner([]), 'linux');
    expect(res.statusCode).toBe(400);
  });

  test('spawn 이 throw → 500', async () => {
    const res = makeRes();
    const spawner = (() => {
      throw new Error('ENOENT');
    }) as never;
    await handleOpenUrl(
      streamReq('{"url":"https://x.test"}') as never,
      res as never,
      spawner,
      'linux',
    );
    expect(res.statusCode).toBe(500);
    expect(res.payload).toEqual({ error: 'Failed to open URL' });
  });
});

describe('handleOpenUrl — URL 검증(보안) #4275', () => {
  const rejected = [
    ['file:// 임의 파일', 'file:///etc/passwd'],
    ['javascript: 스킴', 'javascript:alert(1)'],
    ['커스텀 스킴', 'myapp://launch'],
    ['cmd 메타문자 + 공백', 'https://x.test & calc'],
    ['공백 포함', 'https://x.test/ a'],
    ['백슬래시', 'https://x.test\\foo'],
    ['따옴표', 'https://x.test"q'],
    ['제어문자(CR)', 'https://x.test\r'],
    ['scheme 없음', 'x.test'],
  ] as const;

  for (const [label, url] of rejected) {
    test(`거부: ${label} → 400, spawner 미호출`, async () => {
      const rec: Recorded[] = [];
      const res = makeRes();
      await handleOpenUrl(
        streamReq(JSON.stringify({ url })) as never,
        res as never,
        fakeSpawner(rec),
        'win32',
      );
      expect(rec).toHaveLength(0);
      expect(res.statusCode).toBe(400);
    });
  }

  test('허용: 쿼리스트링(&) 정상 URL → 200 + rundll32 에 그대로 전달', async () => {
    const rec: Recorded[] = [];
    const res = makeRes();
    await handleOpenUrl(
      streamReq('{"url":"https://x.test/?a=1&b=2"}') as never,
      res as never,
      fakeSpawner(rec),
      'win32',
    );
    expect(res.statusCode).toBe(200);
    expect(rec[0]).toMatchObject({
      command: 'rundll32',
      args: ['url.dll,FileProtocolHandler', 'https://x.test/?a=1&b=2'],
    });
  });
});
