// dev HMR 테스트 공용 — `/__hmr` WebSocket broadcast 를 watcher arm-race 에 견고하게 대기.
//
// ## 왜 retry 가 필요한가 (watcher arm-race)
// `waitForServer()` 는 HTTP listen 만 확인하고 native 파일 watcher 의 arm 은 기다리지 않는다
// (별도 subsystem). watcher arm 전에 쓴 변경은 fsevents/inotify 가 *영구히* 놓쳐(이미 지난
// 이벤트는 arm 후 보고되지 않음) broadcast 가 영영 안 온다 — 부하 하에서 드물게 타임아웃.
// 타임아웃을 늘려도 소용없다(영구 miss). 그래서 broadcast 가 올 때까지 trigger 를 주기적으로
// 재호출한다. 정상 경로는 write→broadcast ~60ms 라 첫 trigger 로 끝나고(추가 write 없음),
// 희귀 arm-race miss 만 재시도가 구제한다. broadcast 가 진짜 깨지면(silent drop) 모든 재시도가
// 유실 → 여전히 timeout → silent-drop 회귀 가드 의미 유지.
//
// trigger 는 *고정 내용* 을 다시 써도 된다: 첫 write 가 유실됐다면 bundler 의 last-built
// baseline 은 변경 *전* 상태라, 재시도 write 가 정상 diff(baseline→new)로 잡힌다.
//
// ## teardown
// 모든 종료 경로(predicate 충족 / timeout / ws error)를 단일 settle() 로 통합한다. 한 경로라도
// retry(setInterval) clear 를 빠뜨리면, 호출부 finally 의 rmSync(dir) 이후에도 interval 이 살아
// 삭제된 dir 에 write → ENOENT 가 *다음 테스트*에 오귀속되는 누수 flake 가 된다. settle 은
// settled 가드로 1회만 실행되며 timeout/retry clear + ws.close 를 모든 경로에서 보장하고,
// onopen 은 initialDelay 후 settled 가드로 종료 후 interval 재무장을 차단한다.

export interface HmrMessage {
  type: string;
  [key: string]: unknown;
}

export interface HmrWaitResult {
  /** predicate 를 충족한 메시지. timeout / ws error 시 undefined. */
  result?: HmrMessage;
  /** `connected` 를 제외하고 수신한 메시지 전체(시퀀스 검증용). */
  received: HmrMessage[];
}

export interface HmrWaitOptions {
  /** ws.onopen 후 첫 trigger 까지 대기(ms). 기본 300. */
  initialDelayMs?: number;
  /** broadcast 미수신 시 trigger 재호출 간격(ms). 기본 1500. */
  retryMs?: number;
  /** 전체 대기 상한(ms). 기본 15000. */
  timeoutMs?: number;
}

/**
 * `/__hmr` WebSocket 에 연결해 `trigger()` 로 변경을 일으키고 `predicate` 를 충족하는
 * broadcast 가 올 때까지 기다린다(watcher arm-race 에 견고). 파일 시스템 정리는 호출부가 담당.
 */
export function waitForHmrBroadcast(
  port: number,
  trigger: () => void,
  predicate: (msg: HmrMessage) => boolean,
  opts: HmrWaitOptions = {},
): Promise<HmrWaitResult> {
  const { initialDelayMs = 300, retryMs = 1500, timeoutMs = 15000 } = opts;
  return new Promise<HmrWaitResult>((resolve) => {
    const received: HmrMessage[] = [];
    const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
    let retry: ReturnType<typeof setInterval> | undefined;
    let settled = false;
    const settle = (out: HmrWaitResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (retry) clearInterval(retry);
      try {
        ws.close();
      } catch {
        /* already closing */
      }
      resolve(out);
    };
    const timeout = setTimeout(() => settle({ received }), timeoutMs);
    // trigger() 가 throw 하면(예: 경로 문제) async onopen / setInterval 의 unhandled rejection
    // 대신 settle 로 라우팅 → 호출부 단언이 명확히 실패한다.
    const safeTrigger = () => {
      try {
        trigger();
      } catch {
        settle({ received });
      }
    };
    ws.onopen = async () => {
      await new Promise((r) => setTimeout(r, initialDelayMs));
      if (settled) return; // 대기 중 error/timeout 으로 종료됐으면 interval 안 건다
      safeTrigger();
      retry = setInterval(safeTrigger, retryMs);
    };
    ws.onmessage = (event) => {
      const msg = JSON.parse(String(event.data)) as HmrMessage;
      if (msg.type === 'connected') return; // 핸드셰이크 무시
      received.push(msg);
      if (predicate(msg)) settle({ result: msg, received });
    };
    ws.onerror = () => settle({ received });
  });
}
