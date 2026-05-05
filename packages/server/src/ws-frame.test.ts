import { describe, expect, test } from "bun:test";
import { Buffer } from "node:buffer";
import { EventEmitter } from "node:events";
import type { Socket } from "node:net";

import {
  buildHandshakeResponse,
  buildTextFrame,
  buildTextHeader,
  computeAcceptKey,
  writeTextFrame,
} from "./ws-frame.ts";

class MockSocket extends EventEmitter {
  readonly written: Buffer[] = [];
  destroyed = false;
  write(chunk: Buffer | string): boolean {
    this.written.push(typeof chunk === "string" ? Buffer.from(chunk) : Buffer.from(chunk));
    return true;
  }
}

function asSocket(s: MockSocket): Socket {
  return s as unknown as Socket;
}

describe("buildTextHeader — payload size 별 layout", () => {
  test("0 byte payload (boundary low)", () => {
    const header = buildTextHeader(0);
    expect(header.length).toBe(2);
    expect(header[0]).toBe(0x81);
    expect(header[1]).toBe(0);
  });

  test("125 byte payload (short max)", () => {
    const header = buildTextHeader(125);
    expect(header.length).toBe(2);
    expect(header[1]).toBe(125);
  });

  test("126 byte payload (extended 16 boundary)", () => {
    const header = buildTextHeader(126);
    expect(header.length).toBe(4);
    expect(header[0]).toBe(0x81);
    expect(header[1]).toBe(126);
    expect(header.readUInt16BE(2)).toBe(126);
  });

  test("65535 byte payload (extended 16 max)", () => {
    const header = buildTextHeader(65535);
    expect(header.length).toBe(4);
    expect(header[1]).toBe(126);
    expect(header.readUInt16BE(2)).toBe(65535);
  });

  test("65536 byte payload (extended 64 boundary)", () => {
    const header = buildTextHeader(65536);
    expect(header.length).toBe(10);
    expect(header[0]).toBe(0x81);
    expect(header[1]).toBe(127);
    expect(header.readBigUInt64BE(2)).toBe(65536n);
  });

  test("매우 큰 payload (10 MB)", () => {
    const header = buildTextHeader(10_000_000);
    expect(header.length).toBe(10);
    expect(header[1]).toBe(127);
    expect(header.readBigUInt64BE(2)).toBe(10_000_000n);
  });

  test("FIN bit + opcode 0x1 (text) 가 첫 byte", () => {
    expect(buildTextHeader(50)[0]).toBe(0x81);
    expect(buildTextHeader(200)[0]).toBe(0x81);
    expect(buildTextHeader(70_000)[0]).toBe(0x81);
  });

  test("server-to-client 이라 mask bit 항상 0", () => {
    expect((buildTextHeader(50)[1]! & 0x80) >>> 7).toBe(0);
    expect((buildTextHeader(200)[1]! & 0x80) >>> 7).toBe(0);
    expect((buildTextHeader(70_000)[1]! & 0x80) >>> 7).toBe(0);
  });
});

describe("buildTextFrame — 전체 프레임", () => {
  test("ASCII payload", () => {
    const frame = buildTextFrame("hi");
    expect(frame.length).toBe(4);
    expect(frame[0]).toBe(0x81);
    expect(frame[1]).toBe(2);
    expect(frame.slice(2).toString("utf8")).toBe("hi");
  });

  test("UTF-8 multi-byte payload (한글)", () => {
    const text = "안녕";
    const expectedLength = Buffer.byteLength(text);
    const frame = buildTextFrame(text);
    expect(frame[1]).toBe(expectedLength);
    expect(frame.slice(2).toString("utf8")).toBe(text);
  });

  test("UTF-8 emoji payload (4 byte sequence)", () => {
    const text = "🎉🚀";
    const expectedLength = Buffer.byteLength(text);
    const frame = buildTextFrame(text);
    expect(frame[1]).toBe(expectedLength);
    expect(frame.slice(2).toString("utf8")).toBe(text);
  });

  test("payload length 가 16-bit boundary 를 넘으면 extended header", () => {
    const text = "a".repeat(126);
    const frame = buildTextFrame(text);
    expect(frame.length).toBe(4 + 126);
    expect(frame[1]).toBe(126);
    expect(frame.readUInt16BE(2)).toBe(126);
  });

  test("빈 string payload", () => {
    const frame = buildTextFrame("");
    expect(frame.length).toBe(2);
    expect(frame[1]).toBe(0);
  });
});

describe("writeTextFrame — socket 통합", () => {
  test("정상 socket 에 frame 1회 write", () => {
    const socket = new MockSocket();
    writeTextFrame(asSocket(socket), "ping");
    expect(socket.written.length).toBe(1);
    const frame = socket.written[0]!;
    expect(frame[0]).toBe(0x81);
    expect(frame.slice(2).toString("utf8")).toBe("ping");
  });

  test("destroyed socket 에는 write 안 함 (no-op)", () => {
    const socket = new MockSocket();
    socket.destroyed = true;
    writeTextFrame(asSocket(socket), "ignored");
    expect(socket.written.length).toBe(0);
  });
});

describe("computeAcceptKey — RFC 6455 §1.3", () => {
  test("RFC 6455 spec 예제 검증", () => {
    // Spec example: key="dGhlIHNhbXBsZSBub25jZQ==" → accept="s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    expect(computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==")).toBe("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
  });

  test("같은 key 는 같은 accept", () => {
    const key = "abcdef0123456789";
    expect(computeAcceptKey(key)).toBe(computeAcceptKey(key));
  });

  test("다른 key 는 다른 accept", () => {
    expect(computeAcceptKey("a")).not.toBe(computeAcceptKey("b"));
  });
});

describe("buildHandshakeResponse — HTTP 101 reply", () => {
  test("status line + Upgrade/Connection/Accept header 포함", () => {
    const resp = buildHandshakeResponse("dGhlIHNhbXBsZSBub25jZQ==");
    expect(resp.startsWith("HTTP/1.1 101 Switching Protocols\r\n")).toBe(true);
    expect(resp).toContain("Upgrade: websocket\r\n");
    expect(resp).toContain("Connection: Upgrade\r\n");
    expect(resp).toContain("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n");
  });

  test("CRLF 종결 (header 마지막 + 빈 line)", () => {
    const resp = buildHandshakeResponse("anykey");
    expect(resp.endsWith("\r\n\r\n")).toBe(true);
  });
});
