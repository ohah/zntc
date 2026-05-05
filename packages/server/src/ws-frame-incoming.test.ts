import { describe, expect, test } from "bun:test";

import { parseTextFrame } from "./ws-frame.ts";

function makeMaskedFrame(text: string): Buffer {
  const payload = Buffer.from(text, "utf-8");
  const mask = Buffer.from([0xa1, 0xb2, 0xc3, 0xd4]);
  const masked = Buffer.allocUnsafe(payload.length);
  for (let i = 0; i < payload.length; i++) masked[i] = payload[i]! ^ mask[i % 4]!;

  if (payload.length <= 125) {
    return Buffer.concat([Buffer.from([0x81, 0x80 | payload.length]), mask, masked]);
  }
  if (payload.length <= 65535) {
    const header = Buffer.allocUnsafe(4);
    header[0] = 0x81;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(payload.length, 2);
    return Buffer.concat([header, mask, masked]);
  }
  const header = Buffer.allocUnsafe(10);
  header[0] = 0x81;
  header[1] = 0x80 | 127;
  header.writeBigUInt64BE(BigInt(payload.length), 2);
  return Buffer.concat([header, mask, masked]);
}

describe("parseTextFrame — masked client frames", () => {
  test("short payload (<= 125 bytes)", () => {
    const buf = makeMaskedFrame('{"type":"log"}');
    const result = parseTextFrame(buf);
    expect(result?.text).toBe('{"type":"log"}');
    expect(result?.consumed).toBe(buf.length);
  });

  test("16-bit extended payload (126 ~ 65535)", () => {
    const text = "x".repeat(200);
    const buf = makeMaskedFrame(text);
    expect(parseTextFrame(buf)?.text).toBe(text);
  });

  test("partial buffer → null (incremental)", () => {
    const full = makeMaskedFrame("hello");
    const partial = full.subarray(0, 3);
    expect(parseTextFrame(partial)).toBeNull();
  });

  test("UTF-8 multibyte", () => {
    const buf = makeMaskedFrame("안녕");
    expect(parseTextFrame(buf)?.text).toBe("안녕");
  });
});

describe("parseTextFrame — non-text / control frames → null", () => {
  test("FIN=0 (분할 frame) → null", () => {
    const buf = Buffer.from([0x01, 0x80, 0xa1, 0xb2, 0xc3, 0xd4]);
    expect(parseTextFrame(buf)).toBeNull();
  });

  test("opcode != 0x1 (binary/close/ping) → null", () => {
    const buf = Buffer.from([0x82, 0x80, 0xa1, 0xb2, 0xc3, 0xd4]); // binary
    expect(parseTextFrame(buf)).toBeNull();
  });

  test("unmasked text frame → null (server 만 unmasked)", () => {
    const payload = Buffer.from('{"x":1}');
    const buf = Buffer.concat([Buffer.from([0x81, payload.length]), payload]);
    expect(parseTextFrame(buf)).toBeNull();
  });

  test("buffer 너무 짧음 (header 미만) → null", () => {
    expect(parseTextFrame(Buffer.alloc(0))).toBeNull();
    expect(parseTextFrame(Buffer.from([0x81]))).toBeNull();
  });
});
