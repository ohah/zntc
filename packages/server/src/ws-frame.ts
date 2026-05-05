import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import type { Socket } from "node:net";

import { HMR_WS_GUID } from "./protocol.ts";

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
  return createHash("sha1").update(`${secWebSocketKey}${HMR_WS_GUID}`).digest("base64");
}

export function buildHandshakeResponse(secWebSocketKey: string): string {
  return [
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${computeAcceptKey(secWebSocketKey)}`,
    "",
    "",
  ].join("\r\n");
}
