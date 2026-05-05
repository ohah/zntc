import { describe, expect, test } from 'bun:test';

import { type BunHmrClient, HMR_RN_MSG } from '@zts/server';

import { createMetroHmrAdapter } from './metro-hmr-adapter.ts';

class MockBunClient implements BunHmrClient {
  sent: string[] = [];
  send(text: string): void {
    this.sent.push(text);
  }
}

function parsedSent(client: MockBunClient): unknown[] {
  return client.sent.map((s) => JSON.parse(s));
}

/** addBunClient 후 자동 송출되는 web `connected` greeting 비우기 — RN 메시지만 검증. */
function resetSent(client: MockBunClient): void {
  client.sent.length = 0;
}

describe('createMetroHmrAdapter', () => {
  test('channel 노출 — caller 가 accept / addBunClient 직접 호출 가능', () => {
    const adapter = createMetroHmrAdapter();
    expect(typeof adapter.channel.accept).toBe('function');
    expect(typeof adapter.channel.addBunClient).toBe('function');
    expect(typeof adapter.channel.removeBunClient).toBe('function');
    expect(typeof adapter.channel.broadcast).toBe('function');
    expect(adapter.channel.clientCount).toBe(0);
  });

  test('addBunClient 후 sendUpdate — UpdateStart / Update / UpdateDone 3개 메시지', () => {
    const adapter = createMetroHmrAdapter();
    const client = new MockBunClient();
    adapter.channel.addBunClient(client);
    // greeting (web 의 connected) 먼저 송출 — 첫 메시지는 web HMR_MSG.Connected.
    expect(client.sent.length).toBe(1);
    const greet = JSON.parse(client.sent[0]!);
    expect(greet.type).toBe('connected');

    const modules = [{ id: 'abc', code: '__d(...)' }];
    adapter.sendUpdate(modules);
    const after = parsedSent(client).slice(1);
    expect(after).toEqual([
      { type: HMR_RN_MSG.UpdateStart },
      { type: HMR_RN_MSG.Update, modules },
      { type: HMR_RN_MSG.UpdateDone },
    ]);
  });

  test('sendInitialGreeting — UpdateStart{isInitialUpdate:true} → UpdateDone', () => {
    const adapter = createMetroHmrAdapter();
    const client = new MockBunClient();
    adapter.channel.addBunClient(client);
    resetSent(client); // greeting 비우기

    adapter.sendInitialGreeting();
    expect(parsedSent(client)).toEqual([
      { type: HMR_RN_MSG.UpdateStart, isInitialUpdate: true },
      { type: HMR_RN_MSG.UpdateDone },
    ]);
  });

  test('sendReload — Reload 단일 메시지', () => {
    const adapter = createMetroHmrAdapter();
    const client = new MockBunClient();
    adapter.channel.addBunClient(client);
    resetSent(client);

    adapter.sendReload();
    expect(parsedSent(client)).toEqual([{ type: HMR_RN_MSG.Reload }]);
  });

  test('sendError — Error{message}', () => {
    const adapter = createMetroHmrAdapter();
    const client = new MockBunClient();
    adapter.channel.addBunClient(client);
    resetSent(client);

    adapter.sendError('boom');
    expect(parsedSent(client)).toEqual([{ type: HMR_RN_MSG.Error, message: 'boom' }]);
  });

  test('multi client broadcast — 모든 client 가 같은 메시지 받음', () => {
    const adapter = createMetroHmrAdapter();
    const a = new MockBunClient();
    const b = new MockBunClient();
    adapter.channel.addBunClient(a);
    adapter.channel.addBunClient(b);
    resetSent(a);
    resetSent(b);

    adapter.sendReload();
    expect(parsedSent(a)).toEqual([{ type: HMR_RN_MSG.Reload }]);
    expect(parsedSent(b)).toEqual([{ type: HMR_RN_MSG.Reload }]);
  });

  test('removeBunClient 후 broadcast — 제거된 client 는 받지 않음', () => {
    const adapter = createMetroHmrAdapter();
    const a = new MockBunClient();
    const b = new MockBunClient();
    adapter.channel.addBunClient(a);
    adapter.channel.addBunClient(b);
    adapter.channel.removeBunClient(b);
    resetSent(a);
    resetSent(b);

    adapter.sendReload();
    expect(a.sent.length).toBe(1);
    expect(b.sent.length).toBe(0);
  });

  test('clientCount — addBunClient / removeBunClient 따라 갱신', () => {
    const adapter = createMetroHmrAdapter();
    const a = new MockBunClient();
    const b = new MockBunClient();
    expect(adapter.channel.clientCount).toBe(0);
    adapter.channel.addBunClient(a);
    expect(adapter.channel.clientCount).toBe(1);
    adapter.channel.addBunClient(b);
    expect(adapter.channel.clientCount).toBe(2);
    adapter.channel.removeBunClient(a);
    expect(adapter.channel.clientCount).toBe(1);
  });

  test('sendUpdate — modules 빈 배열도 정상 (3 메시지 송출)', () => {
    const adapter = createMetroHmrAdapter();
    const client = new MockBunClient();
    adapter.channel.addBunClient(client);
    resetSent(client);

    adapter.sendUpdate([]);
    expect(parsedSent(client)).toEqual([
      { type: HMR_RN_MSG.UpdateStart },
      { type: HMR_RN_MSG.Update, modules: [] },
      { type: HMR_RN_MSG.UpdateDone },
    ]);
  });

  test('sendUpdate — modules 의 map 필드 보존', () => {
    const adapter = createMetroHmrAdapter();
    const client = new MockBunClient();
    adapter.channel.addBunClient(client);
    resetSent(client);

    const modules = [{ id: 'x', code: '__d(...)', map: '//# sourceMappingURL=...' }];
    adapter.sendUpdate(modules);
    const update = parsedSent(client)[1] as { modules: Array<Record<string, unknown>> };
    expect(update.modules[0]).toEqual({
      id: 'x',
      code: '__d(...)',
      map: '//# sourceMappingURL=...',
    });
  });

  test('sendUpdate — readonly modules 입력 → adapter 내부 spread 후 broadcast (mutation 안전)', () => {
    const adapter = createMetroHmrAdapter();
    const client = new MockBunClient();
    adapter.channel.addBunClient(client);
    resetSent(client);

    const original = Object.freeze([Object.freeze({ id: 'y', code: 'code' })]);
    expect(() => adapter.sendUpdate(original)).not.toThrow();
    const update = parsedSent(client)[1] as { modules: unknown[] };
    expect(update.modules).toEqual([{ id: 'y', code: 'code' }]);
  });

  test('초기 connect 시 channel 의 자동 greeting (web HmrMessage.Connected) 은 RN adapter 와 무관하게 송출', () => {
    // RN runtime 의 zts-hmr-client.js 는 onmessage 분기에서 'connected' type 을
    // case 안에 두지 않아 default 로 빠짐 (silent ignore). adapter 는 추가
    // greeting (sendInitialGreeting) 을 caller 가 명시 호출.
    const adapter = createMetroHmrAdapter();
    const client = new MockBunClient();
    adapter.channel.addBunClient(client);
    expect(client.sent.length).toBe(1);
    const first = JSON.parse(client.sent[0]!);
    expect(first.type).toBe('connected');
  });
});
