import { describe, test } from "bun:test";
import { expectPass } from "./helpers";

describe("TSC: es2022", () => {
  test("es2022IntlAPIs", async () => {
    await expectPass(
      `
// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/DateTimeFormat/DateTimeFormat#using_timezonename
const timezoneNames = ['short', 'long', 'shortOffset', 'longOffset', 'shortGeneric', 'longGeneric'] as const;
for (const zoneName of timezoneNames) {
  var formatter = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Los_Angeles',
    timeZoneName: zoneName,
  });
}

const enumerationKeys = ['calendar', 'collation', 'currency', 'numberingSystem', 'timeZone', 'unit'] as const;
for (const key of enumerationKeys) {
  var supported = Intl.supportedValuesOf(key);
}`,
      [],
    );
  });
  test("es2022LocalesObjectArgument", async () => {
    await expectPass(
      `
const enUS = new Intl.Locale("en-US");
const deDE = new Intl.Locale("de-DE");
const jaJP = new Intl.Locale("ja-JP");

new Intl.Segmenter(enUS);
new Intl.Segmenter([deDE, jaJP]);
Intl.Segmenter.supportedLocalesOf(enUS);
Intl.Segmenter.supportedLocalesOf([deDE, jaJP]);`,
      [],
    );
  });
  test("es2024SharedMemory", async () => {
    await expectPass(
      `
// ES2024 Atomics.waitAsync was included in the ES2022 type file due to a mistake.
// This test file checks if it fails successfully.
// https://github.com/microsoft/TypeScript/pull/58573#issuecomment-2119347142

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
});
