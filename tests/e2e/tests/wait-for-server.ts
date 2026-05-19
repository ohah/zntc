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
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(2000) });
      await res.body?.cancel(); // 소켓 정리 (body 미소비 시 leak)
      return;
    } catch (e) {
      lastErr = e;
      await new Promise((r) => setTimeout(r, intervalMs));
    }
  }
  const detail = lastErr instanceof Error ? lastErr.message : String(lastErr);
  throw new Error(`waitForServer: ${url} 가 ${timeoutMs}ms 내 응답 없음 (마지막 에러: ${detail})`);
}
