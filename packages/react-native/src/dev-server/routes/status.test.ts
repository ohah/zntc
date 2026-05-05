import { describe, expect, test } from 'bun:test';

import { handleStatus, isStatusRoute } from './status.ts';

describe('isStatusRoute', () => {
  test('/status 매치', () => expect(isStatusRoute('/status')).toBe(true));
  test('/status.txt 매치 (Metro 호환 alias)', () =>
    expect(isStatusRoute('/status.txt')).toBe(true));
  test('/statussuffix 미매치', () => expect(isStatusRoute('/statussuffix')).toBe(false));
  test('/ 미매치', () => expect(isStatusRoute('/')).toBe(false));
});

describe('handleStatus', () => {
  test('Metro 호환 응답 + X-React-Native-Project-Root header', () => {
    let statusCode: number | undefined;
    let body: string | undefined;
    const headers: Record<string, string> = {};
    const res = {
      setHeader(k: string, v: string) {
        headers[k] = v;
      },
      writeHead(code: number) {
        statusCode = code;
      },
      end(b: string) {
        body = b;
      },
    };
    handleStatus({} as never, res as never, '/proj/root');
    expect(statusCode).toBe(200);
    expect(body).toBe('packager-status:running');
    expect(headers['X-React-Native-Project-Root']).toBe('/proj/root');
  });
});
