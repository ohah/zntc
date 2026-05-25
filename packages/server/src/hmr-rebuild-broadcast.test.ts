// broadcastRebuildEvent (#3779) — native watch onRebuild event → HMR channel broadcast
// 분기 변환의 정합성 가드. 메시지 sequence / clear-error 호출 / 분기 outcome 모두 검증.
//
// 가드 핵심:
// - 사용자 incremental HMR 손실 회귀 — code 변경이 있는데 update broadcast 안 함 → noop / fullReload 폴백
// - graph change 와 incremental update 가 동시에 broadcast 되면 client 가 reload+apply 중복 →
//   분기 mutually exclusive 검증

import { describe, expect, test } from 'bun:test';

import { createHmrChannel, type BunHmrClient } from './hmr-channel.ts';
import { HMR_MSG } from './protocol.ts';
import { broadcastRebuildEvent, type RebuildEventLike } from './hmr-rebuild-broadcast.ts';

interface CapturedClient extends BunHmrClient {
  readonly received: string[];
}

function makeClient(): CapturedClient {
  const received: string[] = [];
  return {
    received,
    send(text: string) {
      received.push(text);
    },
  };
}

function attach(): { ch: ReturnType<typeof createHmrChannel>; client: CapturedClient } {
  const ch = createHmrChannel();
  const client = makeClient();
  ch.addBunClient(client);
  // 초기 'connected' 1건은 verification 에서 제외하기 위해 drain.
  client.received.length = 0;
  return { ch, client };
}

function parsed(client: CapturedClient): Array<{ type: string; [k: string]: unknown }> {
  return client.received.map((t) => JSON.parse(t));
}

describe('broadcastRebuildEvent', () => {
  test('success=false → reportError 로 error 메시지 broadcast (latch)', () => {
    const { ch, client } = attach();
    const event: RebuildEventLike = { success: false, error: 'parse failed' };
    const outcome = broadcastRebuildEvent(ch, event);
    expect(outcome).toBe('error');
    const msgs = parsed(client);
    expect(msgs).toHaveLength(1);
    expect(msgs[0].type).toBe(HMR_MSG.Error);
    expect(msgs[0].errors).toEqual([{ file: '', message: 'parse failed' }]);
  });

  test('success=false 인데 error 문자열 없음 → fallback 메시지', () => {
    const { ch, client } = attach();
    const outcome = broadcastRebuildEvent(ch, { success: false });
    expect(outcome).toBe('error');
    const msgs = parsed(client);
    expect(msgs[0].type).toBe(HMR_MSG.Error);
    expect(msgs[0].errors[0].message).toBe('Unknown build error');
  });

  test('graphChanged=true → FullReload broadcast (clearError 동반)', () => {
    const { ch, client } = attach();
    ch.reportError([{ text: 'stale' }]); // 이전 error latch
    client.received.length = 0;
    const outcome = broadcastRebuildEvent(ch, { success: true, graphChanged: true });
    expect(outcome).toBe('full-reload');
    const msgs = parsed(client);
    // clearError 는 broadcast 아니지만, 새 connection 시 송출 안 됨 — 그래서 메시지 수는 1 (FullReload).
    expect(msgs).toHaveLength(1);
    expect(msgs[0].type).toBe(HMR_MSG.FullReload);
    expect(typeof msgs[0].timestamp).toBe('number');
    // clearError 확인 — 새 client 가 연결돼도 error 가 latch 돼 있지 않아야 함.
    const fresh = makeClient();
    ch.addBunClient(fresh);
    expect(fresh.received.map((t) => JSON.parse(t).type)).toEqual([HMR_MSG.Connected]);
  });

  test('updates 있음 + graphChanged=false → UpdateStart → Update → UpdateDone 순서', () => {
    const { ch, client } = attach();
    const event: RebuildEventLike = {
      success: true,
      graphChanged: false,
      updates: [
        { id: '/src/a.ts', code: 'export const a = 1;' },
        { id: '/src/b.ts', code: 'export const b = 2;' },
      ],
    };
    const outcome = broadcastRebuildEvent(ch, event);
    expect(outcome).toBe('update');
    const msgs = parsed(client);
    expect(msgs.map((m) => m.type)).toEqual([HMR_MSG.UpdateStart, HMR_MSG.Update, HMR_MSG.UpdateDone]);
    expect(msgs[1].modules).toEqual([
      { id: '/src/a.ts', code: 'export const a = 1;' },
      { id: '/src/b.ts', code: 'export const b = 2;' },
    ]);
  });

  test('updates 비어있음 + graphChanged=false → noop (broadcast 0건)', () => {
    const { ch, client } = attach();
    const outcome = broadcastRebuildEvent(ch, { success: true, updates: [] });
    expect(outcome).toBe('noop');
    expect(client.received).toHaveLength(0);
  });

  test('updates 없음 (undefined) + graphChanged=false → noop', () => {
    const { ch, client } = attach();
    const outcome = broadcastRebuildEvent(ch, { success: true });
    expect(outcome).toBe('noop');
    expect(client.received).toHaveLength(0);
  });

  test('graphChanged=true 이면 updates 있어도 FullReload 만 (분기 mutually exclusive)', () => {
    const { ch, client } = attach();
    const event: RebuildEventLike = {
      success: true,
      graphChanged: true,
      updates: [{ id: '/src/a.ts', code: 'x' }],
    };
    const outcome = broadcastRebuildEvent(ch, event);
    expect(outcome).toBe('full-reload');
    expect(parsed(client).map((m) => m.type)).toEqual([HMR_MSG.FullReload]);
  });

  test('update 메시지의 modules 는 id/code 만 — sourcemap 등 extra field 누락', () => {
    // RN 측은 map field 도 보내지만 web overlay 의 HmrUpdateModule 은 id/code 만. drift 가드.
    const { ch, client } = attach();
    const event: RebuildEventLike = {
      success: true,
      updates: [
        // 확장 가능한 필드 (map 등) 가 와도 broadcast 시점에서는 떨어져야 함.
        { id: '/x.ts', code: 'c', map: '{"v":3}' } as unknown as { id: string; code: string },
      ],
    };
    broadcastRebuildEvent(ch, event);
    const update = parsed(client).find((m) => m.type === HMR_MSG.Update);
    expect(update?.modules).toEqual([{ id: '/x.ts', code: 'c' }]);
    expect((update?.modules as Array<Record<string, unknown>>)[0]).not.toHaveProperty('map');
  });
});
