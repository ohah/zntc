import { describe, test } from "bun:test";
import { expectPass } from "./helpers";

describe("TSC: es2024", () => {
  test("resizableArrayBuffer", async () => {
    await expectPass(
      `
const buffer = new ArrayBuffer(8, { maxByteLength: 16 });
buffer.resizable;`,
      [],
    );
  });
  test("sharedMemory", async () => {
    await expectPass(
      `
const sab = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 1024);
const int32 = new Int32Array(sab);
const sab64 = new SharedArrayBuffer(BigInt64Array.BYTES_PER_ELEMENT * 1024);
const int64 = new BigInt64Array(sab64);
const waitValue = Atomics.wait(int32, 0, 0);
const { async, value } = Atomics.waitAsync(int32, 0, 0);
const { async: async64, value: value64 } = Atomics.waitAsync(int64, 0, BigInt(0));

const main = async () => {
    if (async) {
        await value;
    }
    if (async64) {
        await value64;
    }
}
main();`,
      [],
    );
  });
  test("transferableArrayBuffer", async () => {
    await expectPass(
      `
const buffer = new ArrayBuffer(8);
const buffer2 = buffer.transfer();

buffer.detached;
buffer2.detached;`,
      [],
    );
  });
});
