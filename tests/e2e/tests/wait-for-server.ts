/**
 * dev/preview 서버 기동 대기 helper.
 *
 * fixed `setTimeout(2000~2500)` 으로 기다리면 느린 CI 에서 서버가 그 안에
 * 못 떠 flaky (BACKLOG #72). 포트가 응답할 때까지 폴링하고, 빠르면 즉시 반환.
 * error-overlay fixture 처럼 500/에러 HTML 을 주는 경우도 "서버는 bind 됨"
 * 으로 간주 — 어떤 HTTP 응답이든 오면 준비 완료.
 */
export async function waitForServer(
  port: number,
  {
    path = '/',
    timeoutMs = 20_000,
    intervalMs = 150,
  }: { path?: string; timeoutMs?: number; intervalMs?: number } = {},
): Promise<void> {
  const url = `http://localhost:${port}${path}`;
  const deadline = Date.now() + timeoutMs;
  let lastErr: unknown;
  while (Date.now() < deadline) {
    // AbortSignal.timeout 은 성공 후에도 타이머가 살아 event loop 에 매달림
    // (14곳 순차 호출 시 누적). 명시 controller + finally clearTimeout 로 정리.
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 2000);
    try {
      const res = await fetch(url, { signal: ctrl.signal });
      // body 미소비 시 소켓 leak. cancel 자체 reject 가 liveness 판정으로
      // 새는 걸 막기 위해 swallow (서버는 이미 응답했으므로 ready 확정).
      await res.body?.cancel().catch(() => {});
      return;
    } catch (e) {
      lastErr = e;
      await new Promise((r) => setTimeout(r, intervalMs));
    } finally {
      clearTimeout(t);
    }
  }
  const detail = lastErr instanceof Error ? lastErr.message : String(lastErr);
  throw new Error(`waitForServer: ${url} 가 ${timeoutMs}ms 내 응답 없음 (마지막 에러: ${detail})`);
}
