import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';
import type { Socket } from 'node:net';

import { HMR_WS_GUID } from './protocol.ts';

// FIN=1, RSV1-3=0, opcode=0x1 (text). server-to-client text frame.
const TEXT_FRAME_FIN_OPCODE = 0x81;

const PAYLOAD_LEN_SHORT_MAX = 125;
const PAYLOAD_LEN_EXTENDED_16 = 126;
const PAYLOAD_LEN_EXTENDED_64 = 127;
const PAYLOAD_LEN_16BIT_MAX = 65535;

/**
 * RFC 6455 §5.2 — text frame builder. payload size 별 header layout:
 *  - <= 125     : 2 byte
 *  - <= 65535   : 4 byte (Extended payload length 16-bit)
 *  - 그 외      : 10 byte (Extended payload length 64-bit)
 *
 * server → client 라 mask bit 0. 단일 frame (FIN=1) 만 emit.
 */
export function buildTextFrame(text: string): Buffer {
  const payload = Buffer.from(text);
  return Buffer.concat([buildTextHeader(payload.length), payload]);
}

export function buildTextHeader(payloadLength: number): Buffer {
  if (payloadLength <= PAYLOAD_LEN_SHORT_MAX) {
    return Buffer.from([TEXT_FRAME_FIN_OPCODE, payloadLength]);
  }
  if (payloadLength <= PAYLOAD_LEN_16BIT_MAX) {
    const header = Buffer.allocUnsafe(4);
    header[0] = TEXT_FRAME_FIN_OPCODE;
    header[1] = PAYLOAD_LEN_EXTENDED_16;
    header.writeUInt16BE(payloadLength, 2);
    return header;
  }
  const header = Buffer.allocUnsafe(10);
  header[0] = TEXT_FRAME_FIN_OPCODE;
  header[1] = PAYLOAD_LEN_EXTENDED_64;
  header.writeBigUInt64BE(BigInt(payloadLength), 2);
  return header;
}

export function writeTextFrame(socket: Socket, text: string): void {
  if (socket.destroyed) return;
  socket.write(buildTextFrame(text));
}

/**
 * RFC 6455 §1.3 — `Sec-WebSocket-Accept = base64(sha1(key + GUID))`.
 */
export function computeAcceptKey(secWebSocketKey: string): string {
  return createHash('sha1').update(`${secWebSocketKey}${HMR_WS_GUID}`).digest('base64');
}

export function buildHandshakeResponse(secWebSocketKey: string): string {
  return [
    'HTTP/1.1 101 Switching Protocols',
    'Upgrade: websocket',
    'Connection: Upgrade',
    `Sec-WebSocket-Accept: ${computeAcceptKey(secWebSocketKey)}`,
    '',
    '',
  ].join('\r\n');
}

/**
 * RFC 6455 §5.2 — client → server text frame parser. masked text frame 만 처리
 * (client 가 보내는 frame 은 항상 masked). control frame (close/ping/pong) /
 * binary / 분할 frame 은 null 반환 — caller 가 ignore.
 *
 * incremental parser — buffer 가 한 frame 미만이면 `{ consumed: 0 }`. caller 가
 * 다음 chunk 와 합쳐 재시도.
 */
export interface ParsedTextFrame {
  text: string;
  consumed: number;
}

export function parseTextFrame(buffer: Buffer): ParsedTextFrame | null {
  if (buffer.length < 2) return null;
  const byte0 = buffer[0]!;
  const byte1 = buffer[1]!;
  const fin = (byte0 & 0x80) !== 0;
  const opcode = byte0 & 0x0f;
  const masked = (byte1 & 0x80) !== 0;
  // text frame (opcode=0x1) + FIN=1 + masked 만. 다른 frame 은 caller skip.
  if (!fin || opcode !== 0x1 || !masked) return null;

  let payloadLen = byte1 & 0x7f;
  let offset = 2;
  if (payloadLen === PAYLOAD_LEN_EXTENDED_16) {
    if (buffer.length < 4) return null;
    payloadLen = buffer.readUInt16BE(2);
    offset = 4;
  } else if (payloadLen === PAYLOAD_LEN_EXTENDED_64) {
    if (buffer.length < 10) return null;
    const big = buffer.readBigUInt64BE(2);
    if (big > BigInt(Number.MAX_SAFE_INTEGER)) return null;
    payloadLen = Number(big);
    offset = 10;
  }
  if (buffer.length < offset + 4 + payloadLen) return null;
  const maskKey = buffer.subarray(offset, offset + 4);
  const payload = Buffer.allocUnsafe(payloadLen);
  for (let i = 0; i < payloadLen; i++) {
    payload[i] = buffer[offset + 4 + i]! ^ maskKey[i % 4]!;
  }
  return { text: payload.toString('utf-8'), consumed: offset + 4 + payloadLen };
}
