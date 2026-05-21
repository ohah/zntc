// 모든 테스트 스위트 (core CLI 테스트 / integration / e2e) 가 공유하는 단일
// dev/preview/serve 서버 readiness 폴링.
//
// 이전엔 3곳에 비슷한 루프가 중복 — 시그니처도 달라 (`(port, maxRetries, interval,
// protocol)` vs `(port, {path,...})` vs inline) 한 곳의 개선이 나머지에 안 옮겨졌다.
// runner 비의존 plain TS — bun:test 와 Playwright 양쪽에서 import 가능.

export interface WaitForServerOptions {
  /** 폴링 경로. default `/`. fixture 가 특정 path 만 응답하는 경우 지정. */
  path?: string;
  /** `http` 또는 `https`. HTTPS dev server (`--certfile`/`--keyfile`) 테스트용. */
  protocol?: 'http' | 'https';
  /** 전체 deadline (ms). default 20_000. */
  timeoutMs?: number;
  /** 시도 간 sleep (ms). default 150. */
  intervalMs?: number;
  /** 단일 요청 timeout (ms). default 2_000. */
  requestTimeoutMs?: number;
  /** ready 로 간주할 응답 status 판정. default = 모든 응답 ready (bind 됐다는 신호로 충분). */
  acceptStatus?: (status: number) => boolean;
  /** 호스트 (default `localhost`). */
  host?: string;
}

/**
 * fixed `setTimeout(2000~2500)` 으로 기다리면 느린 CI 에서 서버가 그 안에 못 떠
 * flaky. 포트가 응답할 때까지 폴링하고, 빠르면 즉시 반환. error-overlay fixture
 * 처럼 500/에러 HTML 을 주는 경우도 "서버는 bind 됨" 으로 간주 — 기본 acceptStatus
 * 가 모든 status 를 ready 로 본다.
 */
export async function waitForServer(port: number, opts: WaitForServerOptions = {}): Promise<void> {
  const path = opts.path ?? '/';
  const protocol = opts.protocol ?? 'http';
  const timeoutMs = opts.timeoutMs ?? 20_000;
  const intervalMs = opts.intervalMs ?? 150;
  const requestTimeoutMs = opts.requestTimeoutMs ?? 2_000;
  const acceptStatus = opts.acceptStatus ?? (() => true);
  const host = opts.host ?? 'localhost';

  const url = `${protocol}://${host}:${port}${path}`;
  const deadline = Date.now() + timeoutMs;
  let lastErr: unknown;

  while (Date.now() < deadline) {
    // AbortSignal.timeout 은 성공 후에도 타이머가 살아 event loop 에 매달림
    // (수십 호출 누적 시 process 종료 지연). 명시 controller + finally clearTimeout 로 정리.
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), requestTimeoutMs);
    let res: Response | undefined;
    try {
      // self-signed cert 거부 회피 — Bun 의 fetch 는 `tls.rejectUnauthorized` 인식.
      // Node 18+ fetch 는 이 옵션을 무시하지만 protocol='https' 사용 시점은 Bun 이라 OK.
      // @ts-expect-error: `tls` 는 Bun fetch 확장, 표준 RequestInit 에 없음
      res = await fetch(url, { signal: ctrl.signal, tls: { rejectUnauthorized: false } });
      if (!acceptStatus(res.status)) {
        throw new Error(`status ${res.status} rejected`);
      }
      return;
    } catch (e) {
      lastErr = e;
      await new Promise((r) => setTimeout(r, intervalMs));
    } finally {
      clearTimeout(t);
      // body 미소비 시 소켓 leak. cancel reject 는 swallow (이미 consumed 등).
      await res?.body?.cancel().catch(() => {});
    }
  }

  const detail = lastErr instanceof Error ? lastErr.message : String(lastErr);
  throw new Error(`waitForServer: ${url} 가 ${timeoutMs}ms 내 응답 없음 (마지막 에러: ${detail})`);
}
