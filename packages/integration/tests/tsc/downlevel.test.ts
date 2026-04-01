import { describe, test, expect } from "bun:test";
import { createFixture, runZts } from "../helpers";

async function expectPass(code: string, flags: string[] = []) {
  const fixture = await createFixture({ "input.ts": code });
  try {
    const result = await runZts([...flags, `${fixture.dir}/input.ts`]);
    expect(result.exitCode).toBe(0);
    expect(result.stderr).not.toContain("error:");
  } finally {
    await fixture.cleanup();
  }
}

async function expectError(code: string, flags: string[] = []) {
  const fixture = await createFixture({ "input.ts": code });
  try {
    const result = await runZts([...flags, `${fixture.dir}/input.ts`]);
    const hasError = result.exitCode !== 0 || result.stderr.includes("error");
    expect(hasError).toBe(true);
  } finally {
    await fixture.cleanup();
  }
}

describe("TSC downlevel conformance", () => {
  describe("es5", () => {
    test("es5DateAPIs", async () => {
      await expectPass(
        `
Date.UTC(2017); // should error`,
        ["--target=es5"],
      );
    });
  });

  describe("es2016", () => {
    test("es2016IntlAPIs", async () => {
      await expectPass(
        `
// Sample from
// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/getCanonicalLocales
console.log(Intl.getCanonicalLocales('EN-US'));
// Expected output: Array ["en-US"]

console.log(Intl.getCanonicalLocales(['EN-US', 'Fr']));
// Expected output: Array ["en-US", "fr"]

try {
  Intl.getCanonicalLocales('EN_US');
} catch (err) {
  console.log(err.toString());
  // Expected output: RangeError: invalid language tag: EN_US
}`,
        [],
      );
    });
  });

  describe("es2017", () => {
    test("assignSharedArrayBufferToArrayBuffer", async () => {
      await expectPass(
        `
var foo: ArrayBuffer = new SharedArrayBuffer(1024); // should error`,
        [],
      );
    });
    test("es2017DateAPIs", async () => {
      await expectPass(
        `
Date.UTC(2017);`,
        [],
      );
    });
    test("useObjectValuesAndEntries1", async () => {
      await expectPass(
        `
var o = { a: 1, b: 2 };

for (var x of Object.values(o)) {
    let y = x;
}

var entries = Object.entries(o);                    // [string, number][]
var values = Object.values(o);                      // number[]

var entries1 = Object.entries(1);                   // [string, any][]
var values1 = Object.values(1);                     // any[]

var entries2 = Object.entries({ a: true, b: 2 });   // [string, number|boolean][]
var values2 = Object.values({ a: true, b: 2 });     // (number|boolean)[]

var entries3 = Object.entries({});                  // [string, {}][]
var values3 = Object.values({});                    // {}[]

var a = ["a", "b", "c"];
var entries4 = Object.entries(a);                   // [string, string][]
var values4 = Object.values(a);                     // string[]

enum E { A, B }
var entries5 = Object.entries(E);                   // [string, any][]
var values5 = Object.values(E);                     // any[]

interface I { }
var i: I = {};
var entries6 = Object.entries(i);                   // [string, any][]
var values6 = Object.values(i);                     // any[]`,
        [],
      );
    });
    test("useObjectValuesAndEntries2", async () => {
      await expectPass(
        `
var o = { a: 1, b: 2 };

for (var x of Object.values(o)) {
    let y = x;
}

var entries = Object.entries(o);`,
        [],
      );
    });
    test("useObjectValuesAndEntries3", async () => {
      await expectPass(
        `
var o = { a: 1, b: 2 };

for (var x of Object.values(o)) {
    let y = x;
}

var entries = Object.entries(o);`,
        [],
      );
    });
    test("useObjectValuesAndEntries4", async () => {
      await expectPass(
        `
var o = { a: 1, b: 2 };

for (var x of Object.values(o)) {
    let y = x;
}

var entries = Object.entries(o);`,
        [],
      );
    });
    test("useSharedArrayBuffer1", async () => {
      await expectPass(
        `
var foge = new SharedArrayBuffer(1024);
var bar = foge.slice(1, 10);
var len = foge.byteLength;`,
        [],
      );
    });
    test("useSharedArrayBuffer2", async () => {
      await expectPass(
        `
var foge = new SharedArrayBuffer(1024);
var bar = foge.slice(1, 10);
var len = foge.byteLength;`,
        [],
      );
    });
    test("useSharedArrayBuffer3", async () => {
      await expectPass(
        `
var foge = new SharedArrayBuffer(1024);
var bar = foge.slice(1, 10);
var len = foge.byteLength;`,
        [],
      );
    });
    test("useSharedArrayBuffer4", async () => {
      await expectPass(
        `
var foge = new SharedArrayBuffer(1024);
var bar = foge.slice(1, 10);
var stringTag = foge[Symbol.toStringTag];
var len = foge.byteLength;
var species = SharedArrayBuffer[Symbol.species];`,
        [],
      );
    });
    test("useSharedArrayBuffer5", async () => {
      await expectPass(
        `
var foge = new SharedArrayBuffer(1024);
var stringTag = foge[Symbol.toStringTag];
var species = SharedArrayBuffer[Symbol.species];`,
        [],
      );
    });
    test("useSharedArrayBuffer6", async () => {
      await expectPass(
        `
var foge = new SharedArrayBuffer(1024);
foge.length; // should error

var length = SharedArrayBuffer.length;
`,
        [],
      );
    });
  });

  describe("es2018", () => {
    test("es2018IntlAPIs", async () => {
      await expectPass(
        `
// Sample from
// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/PluralRules/supportedLocalesOf
const locales = ['ban', 'id-u-co-pinyin', 'de-ID'];
const options = { localeMatcher: 'lookup' } as const;
console.log(Intl.PluralRules.supportedLocalesOf(locales, options).join(', '));

const [ part ] = new Intl.NumberFormat().formatToParts();
console.log(part.type, part.value);
`,
        [],
      );
    });
    test("invalidTaggedTemplateEscapeSequences", async () => {
      await expectError(
        `
function tag (str: any, ...args: any[]): any {
  return str
}

const a = tag\`123\`
const b = tag\`123 \${100}\`
const x = tag\`\\u{hello} \${ 100 } \\xtraordinary \${ 200 } wonderful \${ 300 } \\uworld\`;
const y = \`\\u{hello} \${ 100 } \\xtraordinary \${ 200 } wonderful \${ 300 } \\uworld\`; // should error with NoSubstitutionTemplate
const z = tag\`\\u{hello} \\xtraordinary wonderful \\uworld\` // should work with Tagged NoSubstitutionTemplate

const a1 = tag\`\${ 100 }\\0\` // \\0
const a2 = tag\`\${ 100 }\\00\` // \\\\00
const a3 = tag\`\${ 100 }\\u\` // \\\\u
const a4 = tag\`\${ 100 }\\u0\` // \\\\u0
const a5 = tag\`\${ 100 }\\u00\` // \\\\u00
const a6 = tag\`\${ 100 }\\u000\` // \\\\u000
const a7 = tag\`\${ 100 }\\u0000\` // \\u0000
const a8 = tag\`\${ 100 }\\u{\` // \\\\u{
const a9 = tag\`\${ 100 }\\u{10FFFF}\` // \\\\u{10FFFF
const a10 = tag\`\${ 100 }\\u{1f622\` // \\\\u{1f622
const a11 = tag\`\${ 100 }\\u{1f622}\` // \\u{1f622}
const a12 = tag\`\${ 100 }\\x\` // \\\\x
const a13 = tag\`\${ 100 }\\x0\` // \\\\x0
const a14 = tag\`\${ 100 }\\x00\` // \\x00
`,
        [],
      );
    });
    test("usePromiseFinally", async () => {
      await expectPass(
        `
let promise1 = new Promise(function(resolve, reject) {})
                .finally(function() {});
`,
        [],
      );
    });
    test("useRegexpGroups", async () => {
      await expectPass(
        `
let re = /(?<year>\\d{4})-(?<month>\\d{2})-(?<day>\\d{2})/u;
let result = re.exec("2015-01-02");

let date = result[0];

let year1 = result.groups.year;
let year2 = result[1];

let month1 = result.groups.month;
let month2 = result[2];

let day1 = result.groups.day;
let day2 = result[3];

let foo = "foo".match(/(?<bar>foo)/)!.groups.foo;`,
        [],
      );
    });
  });

  describe("es2019", () => {
    test("allowUnescapedParagraphAndLineSeparatorsInStringLiteral", async () => {
      await expectPass(
        `// Strings containing unescaped line / paragraph separators
// Using both single quotes, double quotes and template literals

var stringContainingUnescapedLineSeparator1 = " STRING_CONTENT ";
var stringContainingUnescapedParagraphSeparator1 = " STRING_CONTENT ";


var stringContainingUnescapedLineSeparator2 = ' STRING_CONTENT ';
var stringContainingUnescapedParagraphSeparator2 = ' STRING_CONTENT ';


var stringContainingUnescapedLineSeparator3 = \` STRING_CONTENT \`;
var stringContainingUnescapedParagraphSeparator3 = \` STRING_CONTENT \`;

// Array of unescaped line / paragraph separators

var arr = [
    "  STRING_CONTENT  ",
    "   STRING_CONTENT   ",
    "STRING_CONTENT ",
    " STRING_CONTENT",
    \`\\ \`,
    ' '
];`,
        [],
      );
    });
    test("globalThisAmbientModules", async () => {
      // tsc는 typeof globalThis에서 ambient module 참조를 타입 에러로 잡지만,
      // ZTS는 타입 체킹을 하지 않으므로 트랜스파일은 성공해야 함.
      // (이전에는 declare module body 내 export 파서 에러로 우연히 실패했음)
      await expectPass(
        `declare module "ambientModule" {
    export type typ = 1
    export var val: typ
}
namespace valueModule { export var val = 1 }
namespace namespaceModule { export type typ = 1 }
// should error (type-level only, not transpilation error)
type GlobalBad1 = (typeof globalThis)["\\"ambientModule\\""]
type GlobalOk1 = (typeof globalThis)["valueModule"]
type GlobalOk2 = globalThis.namespaceModule.typ
const bad1: (typeof globalThis)["\\"ambientModule\\""] = 'ambientModule'`,
        [],
      );
    });
    test("globalThisBlockscopedProperties", async () => {
      await expectPass(
        `var x = 1
const y = 2
let z = 3
globalThis.x // ok
globalThis.y // should error, no property 'y'
globalThis.z // should error, no property 'z'
globalThis['x'] // ok
globalThis['y'] // should error, no property 'y'
globalThis['z'] // should error, no property 'z'
globalThis.Float64Array // ok
globalThis.Infinity // ok

declare let test1: (typeof globalThis)['x'] // ok
declare let test2: (typeof globalThis)['y'] // error
declare let test3: (typeof globalThis)['z'] // error
declare let themAll: keyof typeof globalThis`,
        [],
      );
    });
    test("globalThisCollision", async () => {
      await expectPass(`var globalThis;`, []);
    });
    test("globalThisGlobalExportAsGlobal", async () => {
      await expectPass(
        `// https://github.com/microsoft/TypeScript/issues/33754
declare global {
    export { globalThis as global }
}
`,
        [],
      );
    });
    test("globalThisPropertyAssignment", async () => {
      await expectPass(
        `this.x = 1
var y = 2
// should work in JS
window.z = 3
// should work in JS (even though it's a secondary declaration)
globalThis.alpha = 4`,
        [],
      );
    });
    test("globalThisReadonlyProperties", async () => {
      await expectPass(
        `globalThis.globalThis = 1 as any // should error
var x = 1
const y = 2
globalThis.x = 3
globalThis.y = 4 // should error`,
        [],
      );
    });
    test("globalThisTypeIndexAccess", async () => {
      await expectPass(
        `
declare const w_e: (typeof globalThis)["globalThis"]`,
        [],
      );
    });
    test("globalThisUnknown", async () => {
      await expectPass(
        `declare let win: Window & typeof globalThis;

// this access should be an error
win.hi
// these two should be fine, with type any
this.hi
globalThis.hi

// element access is always ok without noImplicitAny
win['hi']
this['hi']
globalThis['hi']`,
        [],
      );
    });
    test("globalThisUnknownNoImplicitAny", async () => {
      await expectPass(
        `declare let win: Window & typeof globalThis;

// all accesses should be errors
win.hi
this.hi
globalThis.hi

win['hi']
this['hi']
globalThis['hi']`,
        [],
      );
    });
    test("globalThisVarDeclaration", async () => {
      await expectPass(
        `var a = 10;
this.a;
this.b;
globalThis.a;
globalThis.b;

// DOM access is not supported until the index signature is handled more strictly
self.a;
self.b;
window.a;
window.b;
top.a;
top.b;

var b = 10;
this.a;
this.b;
globalThis.a;
globalThis.b;

// same here -- no DOM access to globalThis yet
self.a;
self.b;
window.a;
window.b;
top.a;
top.b;`,
        [],
      );
    });
    test("importMeta", async () => {
      await expectError(
        `

// Adapted from https://github.com/tc39/proposal-import-meta/tree/c3902a9ffe2e69a7ac42c19d7ea74cbdcea9b7fb#example
(async () => {
  const response = await fetch(new URL("../hamsters.jpg", import.meta.url).toString());
  const blob = await response.blob();

  const size = import.meta.scriptElement.dataset.size || 300;

  const image = new Image();
  image.src = URL.createObjectURL(blob);
  image.width = image.height = size;

  document.body.appendChild(image);
})();

export let x = import.meta;
export let y = import.metal;
export let z = import.import.import.malkovich;

let globalA = import.meta;
let globalB = import.metal;
let globalC = import.import.import.malkovich;

export const foo: ImportMeta = import.meta.blah = import.meta.blue = import.meta;
import.meta = foo;

declare global {
  interface ImportMeta {
    wellKnownProperty: { a: number, b: string, c: boolean };
  }
}

const { a, b, c } = import.meta.wellKnownProperty;`,
        [],
      );
    });
    test("importMetaNarrowing", async () => {
      await expectPass(
        `
declare global { interface ImportMeta {foo?: () => void} };

if (import.meta.foo) {
  import.meta.foo();
}`,
        [],
      );
    });
  });

  describe("es2020", () => {
    test("bigintMissingES2019", async () => {
      await expectPass(
        `declare function test<A, B extends A>(): void;

test<{t?: string}, object>();
test<{t?: string}, bigint>();

// no error when bigint is used even when ES2020 lib is not present`,
        [],
      );
    });
    test("bigintMissingES2020", async () => {
      await expectPass(
        `declare function test<A, B extends A>(): void;

test<{t?: string}, object>();
test<{t?: string}, bigint>();

// no error when bigint is used even when ES2020 lib is not present`,
        [],
      );
    });
    test("bigintMissingESNext", async () => {
      await expectPass(
        `declare function test<A, B extends A>(): void;

test<{t?: string}, object>();
test<{t?: string}, bigint>();

// no error when bigint is used even when ES2020 lib is not present`,
        [],
      );
    });
    test("constructBigint", async () => {
      await expectPass(
        `BigInt(1);
BigInt(1n);
BigInt("0");
BigInt(false);

BigInt(Symbol());
BigInt({ e: 1, m: 1 })
BigInt(null);
BigInt(undefined)`,
        [],
      );
    });
    test("es2020IntlAPIs", async () => {
      await expectPass(
        `
// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl#Locale_identification_and_negotiation
const count = 26254.39;
const date = new Date("2012-05-24");

function log(locale: string) {
  console.log(
    \`\${new Intl.DateTimeFormat(locale).format(date)} \${new Intl.NumberFormat(locale).format(count)}\`
  );
}

log("en-US");
// expected output: 5/24/2012 26,254.39

log("de-DE");
// expected output: 24.5.2012 26.254,39

// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/RelativeTimeFormat
const rtf1 = new Intl.RelativeTimeFormat('en', { style: 'narrow' });

console.log(rtf1.format(3, 'quarter'));
//expected output: "in 3 qtrs."

console.log(rtf1.format(-1, 'day'));
//expected output: "1 day ago"

const rtf2 = new Intl.RelativeTimeFormat('es', { numeric: 'auto' });

console.log(rtf2.format(2, 'day'));
//expected output: "pasado mañana"

// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/DisplayNames
const regionNamesInEnglish = new Intl.DisplayNames(['en'], { type: 'region' });
const regionNamesInTraditionalChinese = new Intl.DisplayNames(['zh-Hant'], { type: 'region' });

console.log(regionNamesInEnglish.of('US'));
// expected output: "United States"

console.log(regionNamesInTraditionalChinese.of('US'));
// expected output: "美國"

const locales1 = ['ban', 'id-u-co-pinyin', 'de-ID'];
const options1 = { localeMatcher: 'lookup' } as const;
console.log(Intl.DisplayNames.supportedLocalesOf(locales1, options1).join(', '));

new Intl.Locale(); // should error
new Intl.Locale(new Intl.Locale('en-US'));

new Intl.DisplayNames(); // TypeError: invalid_argument
new Intl.DisplayNames('en'); // TypeError: invalid_argument
new Intl.DisplayNames('en', {}); // TypeError: invalid_argument
console.log((new Intl.DisplayNames(undefined, {type: 'language'})).of('en-GB')); // "British English"

const localesArg = ["es-ES", new Intl.Locale("en-US")];
console.log((new Intl.DisplayNames(localesArg, {type: 'language'})).resolvedOptions().locale); // "es-ES"
console.log(Intl.DisplayNames.supportedLocalesOf(localesArg)); // ["es-ES", "en-US"]
console.log(Intl.DisplayNames.supportedLocalesOf()); // []
console.log(Intl.DisplayNames.supportedLocalesOf(localesArg, {})); // ["es-ES", "en-US"]`,
        [],
      );
    });
    test("intlNumberFormatES2020", async () => {
      await expectPass(
        `
// New/updated resolved options in ES2020
const { notation, style, signDisplay } = new Intl.NumberFormat('en-NZ').resolvedOptions();

// Empty options
new Intl.NumberFormat('en-NZ', {});

// Override numbering system
new Intl.NumberFormat('en-NZ', { numberingSystem: 'arab' });

// Currency
const { currency, currencySign } = new Intl.NumberFormat('en-NZ', { style: 'currency', currency: 'NZD', currencySign: 'accounting' }).resolvedOptions();

// Units
const { unit, unitDisplay } = new Intl.NumberFormat('en-NZ', { style: 'unit', unit: 'kilogram', unitDisplay: 'narrow' }).resolvedOptions();

// Compact
const { compactDisplay } = new Intl.NumberFormat('en-NZ', { notation: 'compact', compactDisplay: 'long' }).resolvedOptions();

// Sign display
new Intl.NumberFormat('en-NZ', { signDisplay: 'always' });

// New additions to NumberFormatPartTypes
const types: Intl.NumberFormatPartTypes[] = [ 'compact', 'unit', 'unknown' ];
`,
        [],
      );
    });
    test("localesObjectArgument", async () => {
      await expectPass(
        `
const enUS = new Intl.Locale("en-US");
const deDE = new Intl.Locale("de-DE");
const jaJP = new Intl.Locale("ja-JP");

const now = new Date();
const num = 1000;
const bigint = 123456789123456789n;
const str = "";

const readonlyLocales: Readonly<string[]> = ['de-DE', 'ja-JP'];

now.toLocaleString(enUS);
now.toLocaleDateString(enUS);
now.toLocaleTimeString(enUS);
now.toLocaleString([deDE, jaJP]);
now.toLocaleDateString([deDE, jaJP]);
now.toLocaleTimeString([deDE, jaJP]);

num.toLocaleString(enUS);
num.toLocaleString([deDE, jaJP]);

bigint.toLocaleString(enUS);
bigint.toLocaleString([deDE, jaJP]);

str.toLocaleLowerCase(enUS);
str.toLocaleLowerCase([deDE, jaJP]);
str.toLocaleUpperCase(enUS);
str.toLocaleUpperCase([deDE, jaJP]);
str.localeCompare(str, enUS);
str.localeCompare(str, [deDE, jaJP]);

new Intl.PluralRules(enUS);
new Intl.PluralRules([deDE, jaJP]);
new Intl.PluralRules(readonlyLocales);
Intl.PluralRules.supportedLocalesOf(enUS);
Intl.PluralRules.supportedLocalesOf([deDE, jaJP]);
Intl.PluralRules.supportedLocalesOf(readonlyLocales);

new Intl.RelativeTimeFormat(enUS);
new Intl.RelativeTimeFormat([deDE, jaJP]);
new Intl.RelativeTimeFormat(readonlyLocales);
Intl.RelativeTimeFormat.supportedLocalesOf(enUS);
Intl.RelativeTimeFormat.supportedLocalesOf([deDE, jaJP]);
Intl.RelativeTimeFormat.supportedLocalesOf(readonlyLocales);

new Intl.Collator(enUS);
new Intl.Collator([deDE, jaJP]);
new Intl.Collator(readonlyLocales);
Intl.Collator.supportedLocalesOf(enUS);
Intl.Collator.supportedLocalesOf([deDE, jaJP]);

new Intl.DateTimeFormat(enUS);
new Intl.DateTimeFormat([deDE, jaJP]);
new Intl.DateTimeFormat(readonlyLocales);
Intl.DateTimeFormat.supportedLocalesOf(enUS);
Intl.DateTimeFormat.supportedLocalesOf([deDE, jaJP]);
Intl.DateTimeFormat.supportedLocalesOf(readonlyLocales);

new Intl.NumberFormat(enUS);
new Intl.NumberFormat([deDE, jaJP]);
new Intl.NumberFormat(readonlyLocales);
Intl.NumberFormat.supportedLocalesOf(enUS);
Intl.NumberFormat.supportedLocalesOf(readonlyLocales);`,
        [],
      );
    });
  });

  describe("emitter/es5", () => {
    test("emitter.asyncGenerators.classMethods.es5", async () => {
      await expectPass(
        `class C1 {
    async * f() {
    }
}
class C2 {
    async * f() {
        const x = yield;
    }
}
class C3 {
    async * f() {
        const x = yield 1;
    }
}
class C4 {
    async * f() {
        const x = yield* [1];
    }
}
class C5 {
    async * f() {
        const x = yield* (async function*() { yield 1; })();
    }
}
class C6 {
    async * f() {
        const x = await 1;
    }
}
class C7 {
    async * f() {
        return 1;
    }
}
class C8 {
    g() {
    }
    async * f() {
        this.g();
    }
}
class B9 {
    g() {}
}
class C9 extends B9 {
    async * f() {
        super.g();
    }
}
`,
        ["--target=es5"],
      );
    });
    test("emitter.asyncGenerators.functionDeclarations.es5", async () => {
      await expectPass(
        `async function * f1() {
}
async function * f2() {
    const x = yield;
}
async function * f3() {
    const x = yield 1;
}
async function * f4() {
    const x = yield* [1];
}
async function * f5() {
    const x = yield* (async function*() { yield 1; })();
}
async function * f6() {
    const x = await 1;
}
async function * f7() {
    return 1;
}
`,
        ["--target=es5"],
      );
    });
    test("emitter.asyncGenerators.functionExpressions.es5", async () => {
      await expectPass(
        `const f1 = async function * () {
}
const f2 = async function * () {
    const x = yield;
}
const f3 = async function * () {
    const x = yield 1;
}
const f4 = async function * () {
    const x = yield* [1];
}
const f5 = async function * () {
    const x = yield* (async function*() { yield 1; })();
}
const f6 = async function * () {
    const x = await 1;
}
const f7 = async function * () {
    return 1;
}
`,
        ["--target=es5"],
      );
    });
    test("emitter.asyncGenerators.objectLiteralMethods.es5", async () => {
      await expectPass(
        `const o1 = {
    async * f() {
    }
}
const o2 = {
    async * f() {
        const x = yield;
    }
}
const o3 = {
    async * f() {
        const x = yield 1;
    }
}
const o4 = {
    async * f() {
        const x = yield* [1];
    }
}
const o5 = {
    async * f() {
        const x = yield* (async function*() { yield 1; })();
    }
}
const o6 = {
    async * f() {
        const x = await 1;
    }
}
const o7 = {
    async * f() {
        return 1;
    }
}
`,
        ["--target=es5"],
      );
    });
  });

  describe("emitter/es2015", () => {
    test("emitter.asyncGenerators.classMethods.es2015", async () => {
      await expectPass(
        `class C1 {
    async * f() {
    }
}
class C2 {
    async * f() {
        const x = yield;
    }
}
class C3 {
    async * f() {
        const x = yield 1;
    }
}
class C4 {
    async * f() {
        const x = yield* [1];
    }
}
class C5 {
    async * f() {
        const x = yield* (async function*() { yield 1; })();
    }
}
class C6 {
    async * f() {
        const x = await 1;
    }
}
class C7 {
    async * f() {
        return 1;
    }
}
class C8 {
    g() {
    }
    async * f() {
        this.g();
    }
}
class B9 {
    g() {}
}
class C9 extends B9 {
    async * f() {
        super.g();
    }
}
`,
        [],
      );
    });
    test("emitter.asyncGenerators.functionDeclarations.es2015", async () => {
      await expectPass(
        `async function * f1() {
}
async function * f2() {
    const x = yield;
}
async function * f3() {
    const x = yield 1;
}
async function * f4() {
    const x = yield* [1];
}
async function * f5() {
    const x = yield* (async function*() { yield 1; })();
}
async function * f6() {
    const x = await 1;
}
async function * f7() {
    return 1;
}
`,
        [],
      );
    });
    test("emitter.asyncGenerators.functionExpressions.es2015", async () => {
      await expectPass(
        `const f1 = async function * () {
}
const f2 = async function * () {
    const x = yield;
}
const f3 = async function * () {
    const x = yield 1;
}
const f4 = async function * () {
    const x = yield* [1];
}
const f5 = async function * () {
    const x = yield* (async function*() { yield 1; })();
}
const f6 = async function * () {
    const x = await 1;
}
const f7 = async function * () {
    return 1;
}
`,
        [],
      );
    });
    test("emitter.asyncGenerators.objectLiteralMethods.es2015", async () => {
      await expectPass(
        `const o1 = {
    async * f() {
    }
}
const o2 = {
    async * f() {
        const x = yield;
    }
}
const o3 = {
    async * f() {
        const x = yield 1;
    }
}
const o4 = {
    async * f() {
        const x = yield* [1];
    }
}
const o5 = {
    async * f() {
        const x = yield* (async function*() { yield 1; })();
    }
}
const o6 = {
    async * f() {
        const x = await 1;
    }
}
const o7 = {
    async * f() {
        return 1;
    }
}
`,
        [],
      );
    });
  });

  describe("emitter/es2018", () => {
    test("emitter.asyncGenerators.classMethods.es2018", async () => {
      await expectPass(
        `class C1 {
    async * f() {
    }
}
class C2 {
    async * f() {
        const x = yield;
    }
}
class C3 {
    async * f() {
        const x = yield 1;
    }
}
class C4 {
    async * f() {
        const x = yield* [1];
    }
}
class C5 {
    async * f() {
        const x = yield* (async function*() { yield 1; })();
    }
}
class C6 {
    async * f() {
        const x = await 1;
    }
}
class C7 {
    async * f() {
        return 1;
    }
}
class C8 {
    g() {
    }
    async * f() {
        this.g();
    }
}
class B9 {
    g() {}
}
class C9 extends B9 {
    async * f() {
        super.g();
    }
}
`,
        [],
      );
    });
    test("emitter.asyncGenerators.functionDeclarations.es2018", async () => {
      await expectPass(
        `async function * f1() {
}
async function * f2() {
    const x = yield;
}
async function * f3() {
    const x = yield 1;
}
async function * f4() {
    const x = yield* [1];
}
async function * f5() {
    const x = yield* (async function*() { yield 1; })();
}
async function * f6() {
    const x = await 1;
}
async function * f7() {
    return 1;
}
`,
        [],
      );
    });
    test("emitter.asyncGenerators.functionExpressions.es2018", async () => {
      await expectPass(
        `const f1 = async function * () {
}
const f2 = async function * () {
    const x = yield;
}
const f3 = async function * () {
    const x = yield 1;
}
const f4 = async function * () {
    const x = yield* [1];
}
const f5 = async function * () {
    const x = yield* (async function*() { yield 1; })();
}
const f6 = async function * () {
    const x = await 1;
}
const f7 = async function * () {
    return 1;
}
`,
        [],
      );
    });
    test("emitter.asyncGenerators.objectLiteralMethods.es2018", async () => {
      await expectPass(
        `const o1 = {
    async * f() {
    }
}
const o2 = {
    async * f() {
        const x = yield;
    }
}
const o3 = {
    async * f() {
        const x = yield 1;
    }
}
const o4 = {
    async * f() {
        const x = yield* [1];
    }
}
const o5 = {
    async * f() {
        const x = yield* (async function*() { yield 1; })();
    }
}
const o6 = {
    async * f() {
        const x = await 1;
    }
}
const o7 = {
    async * f() {
        return 1;
    }
}
`,
        [],
      );
    });
  });

  describe("emitter/es2019", () => {
    test("emitter.noCatchBinding.es2019", async () => {
      await expectPass(
        `function f() {
    try { } catch { }
    try { } catch { 
        try { } catch { }
    }
    try { } catch { } finally { }
}`,
        [],
      );
    });
  });

  describe("async/es5", () => {
    test("asyncAliasReturnType_es5", async () => {
      await expectPass(
        `type PromiseAlias<T> = Promise<T>;

async function f(): PromiseAlias<void> {
}`,
        ["--target=es5"],
      );
    });
    test("arrowFunctionWithParameterNameAsync_es5", async () => {
      await expectPass(
        `
const x = async => async;`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunction1_es5", async () => {
      await expectPass(
        `
var foo = async (): Promise<void> => {
};`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunction10_es5", async () => {
      await expectPass(
        `
var foo = async (): Promise<void> => {
   // Legal to use 'await' in a type context.
   var v: await;
}`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunction11_es5", async () => {
      await expectPass(
        `// https://github.com/Microsoft/TypeScript/issues/24722
class A {
    b = async (...args: any[]) => {
        await Promise.resolve();
        const obj = { ["a"]: () => this }; // computed property name after \`await\` triggers case
    };
}`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunction2_es5", async () => {
      await expectError(
        `var f = (await) => {
}`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunction3_es5", async () => {
      await expectError(
        `function f(await = await) {
}`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunction4_es5", async () => {
      await expectPass(
        `var await = () => {
}`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunction5_es5", async () => {
      await expectPass(
        `
var foo = async (await): Promise<void> => {
}`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunction6_es5", async () => {
      await expectError(
        `
var foo = async (a = await): Promise<void> => {
}`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunction7_es5", async () => {
      await expectError(
        `
var bar = async (): Promise<void> => {
  // 'await' here is an identifier, and not an await expression.
  var foo = async (a = await): Promise<void> => {
  }
}`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunction8_es5", async () => {
      await expectError(
        `
var foo = async (): Promise<void> => {
  var v = { [await]: foo }
}`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunction9_es5", async () => {
      await expectError(
        `var foo = async (a = await => await): Promise<void> => {
}`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunctionCapturesArguments_es5", async () => {
      await expectPass(
        `class C {
   method() {
      function other() {}
      var fn = async () => await other.apply(this, arguments);
   }
}`,
        ["--target=es5"],
      );
    });
    test("asyncArrowFunctionCapturesThis_es5", async () => {
      await expectPass(
        `class C {
   method() {
      var fn = async () => await this;
   }
}`,
        ["--target=es5"],
      );
    });
    test("asyncUnParenthesizedArrowFunction_es5", async () => {
      await expectPass(
        `
declare function someOtherFunction(i: any): Promise<void>;
const x = async i => await someOtherFunction(i)
const x1 = async (i) => await someOtherFunction(i);`,
        ["--target=es5"],
      );
    });
    test("asyncAwait_es5", async () => {
      await expectPass(
        `type MyPromise<T> = Promise<T>;
declare var MyPromise: typeof Promise;
declare var p: Promise<number>;
declare var mp: MyPromise<number>;

async function f0() { }
async function f1(): Promise<void> { }
async function f3(): MyPromise<void> { }

let f4 = async function() { }
let f5 = async function(): Promise<void> { }
let f6 = async function(): MyPromise<void> { }

let f7 = async () => { };
let f8 = async (): Promise<void> => { };
let f9 = async (): MyPromise<void> => { };
let f10 = async () => p;
let f11 = async () => mp;
let f12 = async (): Promise<number> => mp;
let f13 = async (): MyPromise<number> => p;

let o = {
	async m1() { },
	async m2(): Promise<void> { },
	async m3(): MyPromise<void> { }
};

class C {
	async m1() { }
	async m2(): Promise<void> { }
	async m3(): MyPromise<void> { }
	static async m4() { }
	static async m5(): Promise<void> { }
	static async m6(): MyPromise<void> { }
}

namespace M {
	export async function f1() { }
}

async function f14() {
    block: {
        await 1;
        break block;
    }
}`,
        ["--target=es5"],
      );
    });
    test("asyncAwaitNestedClasses_es5", async () => {
      await expectPass(
        `// https://github.com/Microsoft/TypeScript/issues/20744
class A {
    static B = class B {
        static func2(): Promise<void> {
            return new Promise((resolve) => { resolve(null); });
        }
        static C = class C {
            static async func() {
                await B.func2();
            }
        }
    }
}

A.B.C.func();`,
        ["--target=es5"],
      );
    });
    test("asyncClass_es5", async () => {
      await expectError(
        `async class C {
}`,
        ["--target=es5"],
      );
    });
    test("asyncConstructor_es5", async () => {
      await expectError(
        `class C {
  async constructor() {
  }
}`,
        ["--target=es5"],
      );
    });
    test("asyncDeclare_es5", async () => {
      await expectPass(`declare async function foo(): Promise<void>;`, ["--target=es5"]);
    });
    test("asyncEnum_es5", async () => {
      await expectError(
        `async enum E {
  Value
}`,
        ["--target=es5"],
      );
    });
    test("asyncGetter_es5", async () => {
      await expectError(
        `class C {
  async get foo() {
  }
}`,
        ["--target=es5"],
      );
    });
    test("asyncInterface_es5", async () => {
      await expectError(
        `async interface I {
}`,
        ["--target=es5"],
      );
    });
    test("asyncMethodWithSuper_es5", async () => {
      await expectPass(
        `class A {
    x() {
    }
    y() {
    }
}

class B extends A {
    // async method with only call/get on 'super' does not require a binding
    async simple() {
        // call with property access
        super.x();
        // call additional property.
        super.y();

        // call with element access
        super["x"]();

        // property access (read)
        const a = super.x;

        // element access (read)
        const b = super["x"];
    }

    // async method with assignment/destructuring on 'super' requires a binding
    async advanced() {
        const f = () => {};

        // call with property access
        super.x();

        // call with element access
        super["x"]();

        // property access (read)
        const a = super.x;

        // element access (read)
        const b = super["x"];

        // property access (assign)
        super.x = f;

        // element access (assign)
        super["x"] = f;

        // destructuring assign with property access
        ({ f: super.x } = { f });

        // destructuring assign with element access
        ({ f: super["x"] } = { f });
    }
}
`,
        ["--target=es5"],
      );
    });
    test("asyncModule_es5", async () => {
      await expectError(
        `async namespace M {
}`,
        ["--target=es5"],
      );
    });
    test("asyncMultiFile_es5", async () => {
      await expectPass(
        `async function f() {}
function g() { }`,
        ["--target=es5"],
      );
    });
    test("asyncQualifiedReturnType_es5", async () => {
      await expectPass(
        `namespace X {
    export class MyPromise<T> extends Promise<T> {
    }
}

async function f(): X.MyPromise<void> {
}`,
        ["--target=es5"],
      );
    });
    test("asyncSetter_es5", async () => {
      await expectError(
        `class C {
  async set foo(value) {
  }
}`,
        ["--target=es5"],
      );
    });
    test("asyncUseStrict_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
async function func(): Promise<void> {
    "use strict";
    var b = await p || a;
}`,
        ["--target=es5"],
      );
    });
    test("awaitBinaryExpression1_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = await p || a;
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitBinaryExpression2_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = await p && a;
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitBinaryExpression3_es5", async () => {
      await expectPass(
        `declare var a: number;
declare var p: Promise<number>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = await p + a;
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitBinaryExpression4_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = (await p, a);
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitBinaryExpression5_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var o: { a: boolean; };
    o.a = await p;
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitCallExpression1_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = fn(a, a, a);
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitCallExpression2_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = fn(await p, a, a);
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitCallExpression3_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = fn(a, await p, a);
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitCallExpression4_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = (await pfn)(a, a, a);
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitCallExpression5_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = o.fn(a, a, a);
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitCallExpression6_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = o.fn(await p, a, a);
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitCallExpression7_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = o.fn(a, await p, a);
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitCallExpression8_es5", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = (await po).fn(a, a, a);
    after();
}`,
        ["--target=es5"],
      );
    });
    test("awaitClassExpression_es5", async () => {
      await expectPass(
        `declare class C { }
declare var p: Promise<typeof C>;

async function func(): Promise<void> {
    class D extends (await p) {
    }
}`,
        ["--target=es5"],
      );
    });
    test("awaitUnion_es5", async () => {
      await expectPass(
        `declare let a: number | string;
declare let b: PromiseLike<number> | PromiseLike<string>;
declare let c: PromiseLike<number | string>;
declare let d: number | PromiseLike<string>;
declare let e: number | PromiseLike<number | string>;
async function f() {
	let await_a = await a;
	let await_b = await b;
	let await_c = await c;
	let await_d = await d;
	let await_e = await e;
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration1_es5", async () => {
      await expectPass(
        `async function foo(): Promise<void> {
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration10_es5", async () => {
      await expectError(
        `async function foo(a = await => await): Promise<void> {
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration11_es5", async () => {
      await expectPass(
        `async function await(): Promise<void> {
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration12_es5", async () => {
      await expectError(`var v = async function await(): Promise<void> { }`, ["--target=es5"]);
    });
    test("asyncFunctionDeclaration13_es5", async () => {
      await expectPass(
        `async function foo(): Promise<void> {
   // Legal to use 'await' in a type context.
   var v: await;
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration14_es5", async () => {
      await expectPass(
        `async function foo(): Promise<void> {
  return;
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration15_es5", async () => {
      await expectPass(
        `declare class Thenable { then(): void; }
declare let a: any;
declare let obj: { then: string; };
declare let thenable: Thenable;
async function fn1() { } // valid: Promise<void>
async function fn2(): { } { } // error
async function fn3(): any { } // error
async function fn4(): number { } // error
async function fn5(): PromiseLike<void> { } // error
async function fn6(): Thenable { } // error
async function fn7() { return; } // valid: Promise<void>
async function fn8() { return 1; } // valid: Promise<number>
async function fn9() { return null; } // valid: Promise<any>
async function fn10() { return undefined; } // valid: Promise<any>
async function fn11() { return a; } // valid: Promise<any>
async function fn12() { return obj; } // valid: Promise<{ then: string; }>
async function fn13() { return thenable; } // error
async function fn14() { await 1; } // valid: Promise<void>
async function fn15() { await null; } // valid: Promise<void>
async function fn16() { await undefined; } // valid: Promise<void>
async function fn17() { await a; } // valid: Promise<void>
async function fn18() { await obj; } // valid: Promise<void>
async function fn19() { await thenable; } // error
`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration16_es5", async () => {
      await expectPass(
        `
declare class Thenable { then(): void; }

/**
 * @callback T1
 * @param {string} str
 * @returns {string}
 */

/**
 * @callback T2
 * @param {string} str
 * @returns {Promise<string>}
 */

/**
 * @callback T3
 * @param {string} str
 * @returns {Thenable}
 */

/**
 * @param {string} str
 * @returns {string}
 */
const f1 = async str => {
    return str;
}

/** @type {T1} */
const f2 = async str => {
    return str;
}

/**
 * @param {string} str
 * @returns {Promise<string>}
 */
const f3 = async str => {
    return str;
}

/** @type {T2} */
const f4 = async str => {
    return str;
}

/** @type {T3} */
const f5 = async str => {
    return str;
}
`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration2_es5", async () => {
      await expectPass(
        `function f(await) {
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration3_es5", async () => {
      await expectError(
        `function f(await = await) {
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration4_es5", async () => {
      await expectPass(
        `function await() {
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration5_es5", async () => {
      await expectError(
        `async function foo(await): Promise<void> {
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration6_es5", async () => {
      await expectError(
        `async function foo(a = await): Promise<void> {
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration7_es5", async () => {
      await expectError(
        `async function bar(): Promise<void> {
  // 'await' here is an identifier, and not a yield expression.
  async function foo(a = await): Promise<void> {
  }
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclaration8_es5", async () => {
      await expectError(`var v = { [await]: foo }`, ["--target=es5"]);
    });
    test("asyncFunctionDeclaration9_es5", async () => {
      await expectError(
        `async function foo(): Promise<void> {
  var v = { [await]: foo }
}`,
        ["--target=es5"],
      );
    });
    test("asyncFunctionDeclarationCapturesArguments_es5", async () => {
      await expectPass(
        `class C {
   method() {
      function other() {}
      async function fn () {
           await other.apply(this, arguments);
      }
   }
}
`,
        ["--target=es5"],
      );
    });
  });

  describe("async/es6", () => {
    test("asyncAliasReturnType_es6", async () => {
      await expectPass(
        `type PromiseAlias<T> = Promise<T>;

async function f(): PromiseAlias<void> {
}`,
        [],
      );
    });
    test("arrowFunctionWithParameterNameAsync_es6", async () => {
      await expectPass(
        `
const x = async => async;`,
        [],
      );
    });
    test("asyncArrowFunction1_es6", async () => {
      await expectPass(
        `
var foo = async (): Promise<void> => {
};`,
        [],
      );
    });
    test("asyncArrowFunction10_es6", async () => {
      await expectPass(
        `
var foo = async (): Promise<void> => {
   // Legal to use 'await' in a type context.
   var v: await;
}`,
        [],
      );
    });
    test("asyncArrowFunction2_es6", async () => {
      await expectError(
        `var f = (await) => {
}`,
        [],
      );
    });
    test("asyncArrowFunction3_es6", async () => {
      await expectError(
        `function f(await = await) {
}`,
        [],
      );
    });
    test("asyncArrowFunction4_es6", async () => {
      await expectPass(
        `var await = () => {
}`,
        [],
      );
    });
    test("asyncArrowFunction5_es6", async () => {
      await expectPass(
        `
var foo = async (await): Promise<void> => {
}`,
        [],
      );
    });
    test("asyncArrowFunction6_es6", async () => {
      await expectError(
        `
var foo = async (a = await): Promise<void> => {
}`,
        [],
      );
    });
    test("asyncArrowFunction7_es6", async () => {
      await expectError(
        `
var bar = async (): Promise<void> => {
  // 'await' here is an identifier, and not an await expression.
  var foo = async (a = await): Promise<void> => {
  }
}`,
        [],
      );
    });
    test("asyncArrowFunction8_es6", async () => {
      await expectError(
        `
var foo = async (): Promise<void> => {
  var v = { [await]: foo }
}`,
        [],
      );
    });
    test("asyncArrowFunction9_es6", async () => {
      await expectError(
        `var foo = async (a = await => await): Promise<void> => {
}`,
        [],
      );
    });
    test("asyncArrowFunctionCapturesArguments_es6", async () => {
      await expectPass(
        `class C {
   method() {
      function other() {}
      var fn = async () => await other.apply(this, arguments);
   }
}

function f() {
   return async () => async () => arguments.length;
}`,
        [],
      );
    });
    test("asyncArrowFunctionCapturesThis_es6", async () => {
      await expectPass(
        `class C {
   method() {
      var fn = async () => await this;      
   }
}`,
        [],
      );
    });
    test("asyncUnParenthesizedArrowFunction_es6", async () => {
      await expectPass(
        `
declare function someOtherFunction(i: any): Promise<void>;
const x = async i => await someOtherFunction(i)
const x1 = async (i) => await someOtherFunction(i);`,
        [],
      );
    });
    test("asyncAwait_es6", async () => {
      await expectPass(
        `type MyPromise<T> = Promise<T>;
declare var MyPromise: typeof Promise;
declare var p: Promise<number>;
declare var mp: MyPromise<number>;

async function f0() { }
async function f1(): Promise<void> { }
async function f3(): MyPromise<void> { }

let f4 = async function() { }
let f5 = async function(): Promise<void> { }
let f6 = async function(): MyPromise<void> { }

let f7 = async () => { };
let f8 = async (): Promise<void> => { };
let f9 = async (): MyPromise<void> => { };
let f10 = async () => p;
let f11 = async () => mp;
let f12 = async (): Promise<number> => mp;
let f13 = async (): MyPromise<number> => p;

let o = {
	async m1() { },
	async m2(): Promise<void> { },
	async m3(): MyPromise<void> { }
};

class C {
	async m1() { }
	async m2(): Promise<void> { }
	async m3(): MyPromise<void> { }
	static async m4() { }
	static async m5(): Promise<void> { }
	static async m6(): MyPromise<void> { }
}

namespace M {
	export async function f1() { }
}

async function f14() {
    block: {
        await 1;
        break block;
    }
}`,
        [],
      );
    });
    test("asyncClass_es6", async () => {
      await expectError(
        `async class C {  
}`,
        [],
      );
    });
    test("asyncConstructor_es6", async () => {
      await expectError(
        `class C {  
  async constructor() {    
  }
}`,
        [],
      );
    });
    test("asyncDeclare_es6", async () => {
      await expectPass(`declare async function foo(): Promise<void>;`, []);
    });
    test("asyncEnum_es6", async () => {
      await expectError(
        `async enum E {  
  Value
}`,
        [],
      );
    });
    test("asyncGetter_es6", async () => {
      await expectError(
        `class C {
  async get foo() {
  }
}`,
        [],
      );
    });
    test("asyncInterface_es6", async () => {
      await expectError(
        `async interface I {  
}`,
        [],
      );
    });
    test("asyncMethodWithSuper_es6", async () => {
      await expectPass(
        `class A {
    x() {
    }
    y() {
    }
}

class B extends A {
    // async method with only call/get on 'super' does not require a binding
    async simple() {
        // call with property access
        super.x();
        // call additional property.
        super.y();

        // call with element access
        super["x"]();

        // property access (read)
        const a = super.x;

        // element access (read)
        const b = super["x"];
    }

    // async method with assignment/destructuring on 'super' requires a binding
    async advanced() {
        const f = () => {};

        // call with property access
        super.x();

        // call with element access
        super["x"]();

        // property access (read)
        const a = super.x;

        // element access (read)
        const b = super["x"];

        // property access (assign)
        super.x = f;

        // element access (assign)
        super["x"] = f;

        // destructuring assign with property access
        ({ f: super.x } = { f });

        // destructuring assign with element access
        ({ f: super["x"] } = { f });

        // property access in arrow
        (() => super.x());

        // element access in arrow
        (() => super["x"]());

        // property access in async arrow
        (async () => super.x());

        // element access in async arrow
        (async () => super["x"]());
    }

    async property_access_only_read_only() {
        // call with property access
        super.x();

        // property access (read)
        const a = super.x;

        // property access in arrow
        (() => super.x());

        // property access in async arrow
        (async () => super.x());
    }

    async property_access_only_write_only() {
        const f = () => {};

        // property access (assign)
        super.x = f;

        // destructuring assign with property access
        ({ f: super.x } = { f });

        // property access (assign) in arrow
        (() => super.x = f);

        // property access (assign) in async arrow
        (async () => super.x = f);
    }

    async element_access_only_read_only() {
        // call with element access
        super["x"]();

        // element access (read)
        const a = super["x"];

        // element access in arrow
        (() => super["x"]());

        // element access in async arrow
        (async () => super["x"]());
    }

    async element_access_only_write_only() {
        const f = () => {};

        // element access (assign)
        super["x"] = f;

        // destructuring assign with element access
        ({ f: super["x"] } = { f });

        // element access (assign) in arrow
        (() => super["x"] = f);

        // element access (assign) in async arrow
        (async () => super["x"] = f);
    }

    async * property_access_only_read_only_in_generator() {
        // call with property access
        super.x();

        // property access (read)
        const a = super.x;

        // property access in arrow
        (() => super.x());

        // property access in async arrow
        (async () => super.x());
    }

    async * property_access_only_write_only_in_generator() {
        const f = () => {};

        // property access (assign)
        super.x = f;

        // destructuring assign with property access
        ({ f: super.x } = { f });

        // property access (assign) in arrow
        (() => super.x = f);

        // property access (assign) in async arrow
        (async () => super.x = f);
    }

    async * element_access_only_read_only_in_generator() {
        // call with element access
        super["x"]();

        // element access (read)
        const a = super["x"];

        // element access in arrow
        (() => super["x"]());

        // element access in async arrow
        (async () => super["x"]());
    }

    async * element_access_only_write_only_in_generator() {
        const f = () => {};

        // element access (assign)
        super["x"] = f;

        // destructuring assign with element access
        ({ f: super["x"] } = { f });

        // element access (assign) in arrow
        (() => super["x"] = f);

        // element access (assign) in async arrow
        (async () => super["x"] = f);
    }
}

// https://github.com/microsoft/TypeScript/issues/46828
class Base {
    set setter(x: any) {}
    get getter(): any { return; }
    method(x: string): any {}

    static set setter(x: any) {}
    static get getter(): any { return; }
    static method(x: string): any {}
}

class Derived extends Base {
    a() { return async () => super.method('') }
    b() { return async () => super.getter }
    c() { return async () => super.setter = '' }
    d() { return async () => super["method"]('') }
    e() { return async () => super["getter"] }
    f() { return async () => super["setter"] = '' }
    static a() { return async () => super.method('') }
    static b() { return async () => super.getter }
    static c() { return async () => super.setter = '' }
    static d() { return async () => super["method"]('') }
    static e() { return async () => super["getter"] }
    static f() { return async () => super["setter"] = '' }
}
`,
        [],
      );
    });
    test("asyncModule_es6", async () => {
      await expectError(
        `async namespace M {   
}`,
        [],
      );
    });
    test("asyncMultiFile_es6", async () => {
      await expectPass(
        `async function f() {}
function g() { }`,
        [],
      );
    });
    test("asyncQualifiedReturnType_es6", async () => {
      await expectPass(
        `namespace X {
    export class MyPromise<T> extends Promise<T> {
    }
}

async function f(): X.MyPromise<void> {
}`,
        [],
      );
    });
    test("asyncSetter_es6", async () => {
      await expectError(
        `class C {
  async set foo(value) {
  }
}`,
        [],
      );
    });
    test("asyncUseStrict_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
async function func(): Promise<void> {
    "use strict";
    var b = await p || a;
}`,
        [],
      );
    });
    test("asyncWithVarShadowing_es6", async () => {
      await expectPass(
        `// https://github.com/Microsoft/TypeScript/issues/20461
declare const y: any;

async function fn1(x) {
    var x;
}

async function fn2(x) {
    var x, z;
}

async function fn3(x) {
    var z;
}

async function fn4(x) {
    var x = y;
}

async function fn5(x) {
    var { x } = y;
}

async function fn6(x) {
    var { x, z } = y;
}

async function fn7(x) {
    var { x = y } = y;
}

async function fn8(x) {
    var { z: x } = y;
}

async function fn9(x) {
    var { z: { x } } = y;
}

async function fn10(x) {
    var { z: { x } = y } = y;
}

async function fn11(x) {
    var { ...x } = y;
}

async function fn12(x) {
    var [x] = y;
}

async function fn13(x) {
    var [x = y] = y;
}

async function fn14(x) {
    var [, x] = y;
}

async function fn15(x) {
    var [...x] = y;
}

async function fn16(x) {
    var [[x]] = y;
}

async function fn17(x) {
    var [[x] = y] = y;
}

async function fn18({ x }) {
    var x;
}

async function fn19([x]) {
    var x;
}

async function fn20(x) {
    {
        var x;
    }
}

async function fn21(x) {
    if (y) {
        var x;
    }
}

async function fn22(x) {
    if (y) {
    }
    else {
        var x;
    }
}

async function fn23(x) {
    try {
        var x;
    }
    catch (e) {
    }
}

async function fn24(x) {
    try {

    }
    catch (e) {
        var x;
    }
}

async function fn25(x) {
    try {

    }
    catch (x) {
        var x;
    }
}

async function fn26(x) {
    try {

    }
    catch ({ x }) {
        var x;
    }
}

async function fn27(x) {
    try {
    }
    finally {
        var x;
    }
}

async function fn28(x) {
    while (y) {
        var x;
    }
}

async function fn29(x) {
    do {
        var x;
    }
    while (y);
}

async function fn30(x) {
    for (var x = y;;) {

    }
}

async function fn31(x) {
    for (var { x } = y;;) {
    }
}

async function fn32(x) {
    for (;;) {
        var x;
    }
}

async function fn33(x: string) {
    for (var x in y) {
    }
}

async function fn34(x) {
    for (var z in y) {
        var x;
    }
}

async function fn35(x) {
    for (var x of y) {
    }
}

async function fn36(x) {
    for (var { x } of y) {
    }
}

async function fn37(x) {
    for (var z of y) {
        var x;
    }
}

async function fn38(x) {
    switch (y) {
        case y:
            var x;
    }
}

async function fn39(x) {
    foo: {
        var x;
        break foo;
    }
}

async function fn40(x) {
    try {

    }
    catch {
        var x;
    }
}
`,
        [],
      );
    });
    test("await_unaryExpression_es6_1", async () => {
      await expectPass(
        `// @target: es6

async function bar() {
    !await 42; // OK
}

async function bar1() {
    delete await 42; // OK
}

async function bar2() {
    delete await 42; // OK
}

async function bar3() {
    void await 42;
}

async function bar4() {
    +await 42;
}`,
        [],
      );
    });
    test("await_unaryExpression_es6_2", async () => {
      await expectPass(
        `// @target: es6

async function bar1() {
    delete await 42;
}

async function bar2() {
    delete await 42;
}

async function bar3() {
    void await 42;
}`,
        [],
      );
    });
    test("await_unaryExpression_es6_3", async () => {
      await expectError(
        `// @target: es6

async function bar1() {
    ++await 42; // Error
}

async function bar2() {
    --await 42; // Error
}

async function bar3() {
    var x = 42;
    await x++; // OK but shouldn't need parenthesis
}

async function bar4() {
    var x = 42;
    await x--; // OK but shouldn't need parenthesis
}`,
        [],
      );
    });
    test("await_unaryExpression_es6", async () => {
      await expectPass(
        `// @target: es6

async function bar() {
    !await 42; // OK
}

async function bar1() {
    +await 42; // OK
}

async function bar3() {
    -await 42; // OK
}

async function bar4() {
    ~await 42; // OK
}`,
        [],
      );
    });
    test("awaitBinaryExpression1_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = await p || a;
    after();
}`,
        [],
      );
    });
    test("awaitBinaryExpression2_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = await p && a;
    after();
}`,
        [],
      );
    });
    test("awaitBinaryExpression3_es6", async () => {
      await expectPass(
        `declare var a: number;
declare var p: Promise<number>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = await p + a;
    after();
}`,
        [],
      );
    });
    test("awaitBinaryExpression4_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = (await p, a);
    after();
}`,
        [],
      );
    });
    test("awaitBinaryExpression5_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var o: { a: boolean; };
    o.a = await p;
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression1_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = fn(a, a, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression2_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = fn(await p, a, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression3_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = fn(a, await p, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression4_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = (await pfn)(a, a, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression5_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = o.fn(a, a, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression6_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = o.fn(await p, a, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression7_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = o.fn(a, await p, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression8_es6", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = (await po).fn(a, a, a);
    after();
}`,
        [],
      );
    });
    test("awaitClassExpression_es6", async () => {
      await expectPass(
        `declare class C { }
declare var p: Promise<typeof C>;

async function func(): Promise<void> {
    class D extends (await p) {
    }
}`,
        [],
      );
    });
    test("awaitUnion_es6", async () => {
      await expectPass(
        `declare let a: number | string;
declare let b: PromiseLike<number> | PromiseLike<string>;
declare let c: PromiseLike<number | string>;
declare let d: number | PromiseLike<string>;
declare let e: number | PromiseLike<number | string>;
async function f() {
	let await_a = await a;
	let await_b = await b;
	let await_c = await c;
	let await_d = await d;
	let await_e = await e;
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration1_es6", async () => {
      await expectPass(
        `async function foo(): Promise<void> {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration10_es6", async () => {
      await expectError(
        `async function foo(a = await => await): Promise<void> {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration11_es6", async () => {
      await expectPass(
        `async function await(): Promise<void> {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration12_es6", async () => {
      await expectError(`var v = async function await(): Promise<void> { }`, []);
    });
    test("asyncFunctionDeclaration13_es6", async () => {
      await expectPass(
        `async function foo(): Promise<void> {
   // Legal to use 'await' in a type context.
   var v: await;
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration14_es6", async () => {
      await expectPass(
        `async function foo(): Promise<void> {
  return;
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration15_es6", async () => {
      await expectPass(
        `declare class Thenable { then(): void; }
declare let a: any;
declare let obj: { then: string; };
declare let thenable: Thenable;
async function fn1() { } // valid: Promise<void>
async function fn2(): { } { } // error
async function fn3(): any { } // error
async function fn4(): number { } // error
async function fn5(): PromiseLike<void> { } // error
async function fn6(): Thenable { } // error
async function fn7() { return; } // valid: Promise<void>
async function fn8() { return 1; } // valid: Promise<number>
async function fn9() { return null; } // valid: Promise<any>
async function fn10() { return undefined; } // valid: Promise<any>
async function fn11() { return a; } // valid: Promise<any>
async function fn12() { return obj; } // valid: Promise<{ then: string; }>
async function fn13() { return thenable; } // error
async function fn14() { await 1; } // valid: Promise<void>
async function fn15() { await null; } // valid: Promise<void>
async function fn16() { await undefined; } // valid: Promise<void>
async function fn17() { await a; } // valid: Promise<void>
async function fn18() { await obj; } // valid: Promise<void>
async function fn19() { await thenable; } // error
`,
        [],
      );
    });
    test("asyncFunctionDeclaration2_es6", async () => {
      await expectPass(
        `function f(await) {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration3_es6", async () => {
      await expectError(
        `function f(await = await) {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration4_es6", async () => {
      await expectPass(
        `function await() {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration5_es6", async () => {
      await expectError(
        `async function foo(await): Promise<void> {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration6_es6", async () => {
      await expectError(
        `async function foo(a = await): Promise<void> {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration7_es6", async () => {
      await expectError(
        `async function bar(): Promise<void> {
  // 'await' here is an identifier, and not a yield expression.
  async function foo(a = await): Promise<void> {
  }
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration8_es6", async () => {
      await expectError(`var v = { [await]: foo }`, []);
    });
    test("asyncFunctionDeclaration9_es6", async () => {
      await expectError(
        `async function foo(): Promise<void> {
  var v = { [await]: foo }
}`,
        [],
      );
    });
    test("asyncOrYieldAsBindingIdentifier1", async () => {
      await expectError(
        `
function f_let () {
    let await = 1
}

function f1_var () {
    var await = 1
}

function f1_const () {
    const await = 1
}

async function f2_let () {
    let await = 1
}

async function f2_var () {
    var await = 1
}

async function f2_const () {
    const await = 1
}

function f3_let () {
    let yield = 2
}

function f3_var () {
    var yield = 2
}

function f3_const () {
    const yield = 2
}

function * f4_let () {
    let yield = 2;
}

function * f4_var () {
    var yield = 2;
}

function * f4_const () {
    const yield = 2;
}`,
        [],
      );
    });
  });

  describe("async/es2017", () => {
    test("arrowFunctionWithParameterNameAsync_es2017", async () => {
      await expectPass(
        `
const x = async => async;`,
        [],
      );
    });
    test("asyncArrowFunction_allowJs", async () => {
      await expectPass(
        `
// Error (good)
/** @type {function(): string} */
const a = () => 0

// Error (good)
/** @type {function(): string} */
const b = async () => 0

// No error (bad)
/** @type {function(): string} */
const c = async () => {
	return 0
}

// Error (good)
/** @type {function(): string} */
const d = async () => {
	return ""
}

/** @type {function(function(): string): void} */
const f = (p) => {}

// Error (good)
f(async () => {
	return 0
})`,
        [],
      );
    });
    test("asyncArrowFunction1_es2017", async () => {
      await expectPass(
        `
var foo = async (): Promise<void> => {
};`,
        [],
      );
    });
    test("asyncArrowFunction10_es2017", async () => {
      await expectPass(
        `
var foo = async (): Promise<void> => {
   // Legal to use 'await' in a type context.
   var v: await;
}`,
        [],
      );
    });
    test("asyncArrowFunction2_es2017", async () => {
      await expectError(
        `var f = (await) => {
}`,
        [],
      );
    });
    test("asyncArrowFunction3_es2017", async () => {
      await expectError(
        `function f(await = await) {
}`,
        [],
      );
    });
    test("asyncArrowFunction4_es2017", async () => {
      await expectPass(
        `var await = () => {
}`,
        [],
      );
    });
    test("asyncArrowFunction5_es2017", async () => {
      await expectPass(
        `
var foo = async (await): Promise<void> => {
}`,
        [],
      );
    });
    test("asyncArrowFunction6_es2017", async () => {
      await expectError(
        `
var foo = async (a = await): Promise<void> => {
}`,
        [],
      );
    });
    test("asyncArrowFunction7_es2017", async () => {
      await expectError(
        `
var bar = async (): Promise<void> => {
  // 'await' here is an identifier, and not an await expression.
  var foo = async (a = await): Promise<void> => {
  }
}`,
        [],
      );
    });
    test("asyncArrowFunction8_es2017", async () => {
      await expectError(
        `
var foo = async (): Promise<void> => {
  var v = { [await]: foo }
}`,
        [],
      );
    });
    test("asyncArrowFunction9_es2017", async () => {
      await expectError(
        `var foo = async (a = await => await): Promise<void> => {
}`,
        [],
      );
    });
    test("asyncArrowFunctionCapturesArguments_es2017", async () => {
      await expectPass(
        `class C {
   method() {
      function other() {}
      var fn = async () => await other.apply(this, arguments);      
   }
}`,
        [],
      );
    });
    test("asyncArrowFunctionCapturesThis_es2017", async () => {
      await expectPass(
        `class C {
   method() {
      var fn = async () => await this;      
   }
}`,
        [],
      );
    });
    test("asyncUnParenthesizedArrowFunction_es2017", async () => {
      await expectPass(
        `
declare function someOtherFunction(i: any): Promise<void>;
const x = async i => await someOtherFunction(i)
const x1 = async (i) => await someOtherFunction(i);`,
        [],
      );
    });
    test("asyncAwait_es2017", async () => {
      await expectPass(
        `type MyPromise<T> = Promise<T>;
declare var MyPromise: typeof Promise;
declare var p: Promise<number>;
declare var mp: MyPromise<number>;

async function f0() { }
async function f1(): Promise<void> { }
async function f3(): MyPromise<void> { }

let f4 = async function() { }
let f5 = async function(): Promise<void> { }
let f6 = async function(): MyPromise<void> { }

let f7 = async () => { };
let f8 = async (): Promise<void> => { };
let f9 = async (): MyPromise<void> => { };
let f10 = async () => p;
let f11 = async () => mp;
let f12 = async (): Promise<number> => mp;
let f13 = async (): MyPromise<number> => p;

let o = {
	async m1() { },
	async m2(): Promise<void> { },
	async m3(): MyPromise<void> { }
};

class C {
	async m1() { }
	async m2(): Promise<void> { }
	async m3(): MyPromise<void> { }
	static async m4() { }
	static async m5(): Promise<void> { }
	static async m6(): MyPromise<void> { }
}

namespace M {
	export async function f1() { }
}

async function f14() {
    block: {
        await 1;
        break block;
    }
}`,
        [],
      );
    });
    test("asyncMethodWithSuper_es2017", async () => {
      await expectPass(
        `class A {
    x() {
    }
    y() {
    }
}

class B extends A {
    // async method with only call/get on 'super' does not require a binding
    async simple() {
        // call with property access
        super.x();
        // call additional property.
        super.y();

        // call with element access
        super["x"]();

        // property access (read)
        const a = super.x;

        // element access (read)
        const b = super["x"];
    }

    // async method with assignment/destructuring on 'super' requires a binding
    async advanced() {
        const f = () => {};

        // call with property access
        super.x();

        // call with element access
        super["x"]();

        // property access (read)
        const a = super.x;

        // element access (read)
        const b = super["x"];

        // property access (assign)
        super.x = f;

        // element access (assign)
        super["x"] = f;

        // destructuring assign with property access
        ({ f: super.x } = { f });

        // destructuring assign with element access
        ({ f: super["x"] } = { f });
    }
}
`,
        [],
      );
    });
    test("asyncMethodWithSuperConflict_es6", async () => {
      await expectPass(
        `class A {
    x() {
    }
    y() {
    }
}

class B extends A {
    // async method with only call/get on 'super' does not require a binding
    async simple() {
        const _super = null;
        const _superIndex = null;
        // call with property access
        super.x();
        // call additional property.
        super.y();

        // call with element access
        super["x"]();

        // property access (read)
        const a = super.x;

        // element access (read)
        const b = super["x"];
    }

    // async method with assignment/destructuring on 'super' requires a binding
    async advanced() {
        const _super = null;
        const _superIndex = null;
        const f = () => {};

        // call with property access
        super.x();

        // call with element access
        super["x"]();

        // property access (read)
        const a = super.x;

        // element access (read)
        const b = super["x"];

        // property access (assign)
        super.x = f;

        // element access (assign)
        super["x"] = f;

        // destructuring assign with property access
        ({ f: super.x } = { f });

        // destructuring assign with element access
        ({ f: super["x"] } = { f });
    }
}
`,
        [],
      );
    });
    test("asyncUseStrict_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
async function func(): Promise<void> {
    "use strict";
    var b = await p || a;
}`,
        [],
      );
    });
    test("await_incorrectThisType", async () => {
      await expectPass(
        `
// https://github.com/microsoft/TypeScript/issues/47711
type Either<E, A> = Left<E> | Right<A>;
type Left<E> = { tag: 'Left', e: E };
type Right<A> = { tag: 'Right', a: A };

const mkLeft = <E>(e: E): Either<E, never> => ({ tag: 'Left', e });
const mkRight = <A>(a: A): Either<never, A> => ({ tag: 'Right', a });

class EPromise<E, A> implements PromiseLike<A> {
    static succeed<A>(a: A): EPromise<never, A> {
        return new EPromise(Promise.resolve(mkRight(a)));
    }

    static fail<E>(e: E): EPromise<E, never> {
        return new EPromise(Promise.resolve(mkLeft(e)));
    }

    constructor(readonly p: PromiseLike<Either<E, A>>) { }

    then<B = A, B1 = never>(
        // EPromise can act as a Thenable only when \`E\` is \`never\`.
        this: EPromise<never, A>,
        onfulfilled?: ((value: A) => B | PromiseLike<B>) | null | undefined,
        onrejected?: ((reason: any) => B1 | PromiseLike<B1>) | null | undefined
    ): PromiseLike<B | B1> {
        return this.p.then(
            // Casting to \`Right<A>\` is safe here because we've eliminated the possibility of \`Left<E>\`.
            either => onfulfilled?.((either as Right<A>).a) ?? (either as Right<A>).a as unknown as B,
            onrejected
        )
    }
}

const withTypedFailure: EPromise<number, string> = EPromise.fail(1);

// Errors as expected:
//
// "The 'this' context of type 'EPromise<number, string>' is not assignable to method's
//     'this' of type 'EPromise<never, string>"
withTypedFailure.then(s => s.toUpperCase()).then(console.log);

async function test() {
    await withTypedFailure;
}`,
        [],
      );
    });
    test("await_unaryExpression_es2017_1", async () => {
      await expectPass(
        `// @target: es2017

async function bar() {
    !await 42; // OK
}

async function bar1() {
    delete await 42; // OK
}

async function bar2() {
    delete await 42; // OK
}

async function bar3() {
    void await 42;
}

async function bar4() {
    +await 42;
}`,
        [],
      );
    });
    test("await_unaryExpression_es2017_2", async () => {
      await expectPass(
        `// @target: es2017

async function bar1() {
    delete await 42;
}

async function bar2() {
    delete await 42;
}

async function bar3() {
    void await 42;
}`,
        [],
      );
    });
    test("await_unaryExpression_es2017_3", async () => {
      await expectError(
        `// @target: es2017

async function bar1() {
    ++await 42; // Error
}

async function bar2() {
    --await 42; // Error
}

async function bar3() {
    var x = 42;
    await x++; // OK but shouldn't need parenthesis
}

async function bar4() {
    var x = 42;
    await x--; // OK but shouldn't need parenthesis
}`,
        [],
      );
    });
    test("await_unaryExpression_es2017", async () => {
      await expectPass(
        `// @target: es2017

async function bar() {
    !await 42; // OK
}

async function bar1() {
    +await 42; // OK
}

async function bar3() {
    -await 42; // OK
}

async function bar4() {
    ~await 42; // OK
}`,
        [],
      );
    });
    test("awaitBinaryExpression1_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = await p || a;
    after();
}`,
        [],
      );
    });
    test("awaitBinaryExpression2_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = await p && a;
    after();
}`,
        [],
      );
    });
    test("awaitBinaryExpression3_es2017", async () => {
      await expectPass(
        `declare var a: number;
declare var p: Promise<number>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = await p + a;
    after();
}`,
        [],
      );
    });
    test("awaitBinaryExpression4_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = (await p, a);
    after();
}`,
        [],
      );
    });
    test("awaitBinaryExpression5_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var o: { a: boolean; };
    o.a = await p;
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression1_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = fn(a, a, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression2_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = fn(await p, a, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression3_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = fn(a, await p, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression4_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = (await pfn)(a, a, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression5_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = o.fn(a, a, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression6_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = o.fn(await p, a, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression7_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = o.fn(a, await p, a);
    after();
}`,
        [],
      );
    });
    test("awaitCallExpression8_es2017", async () => {
      await expectPass(
        `declare var a: boolean;
declare var p: Promise<boolean>;
declare function fn(arg0: boolean, arg1: boolean, arg2: boolean): void;
declare var o: { fn(arg0: boolean, arg1: boolean, arg2: boolean): void; };
declare var pfn: Promise<{ (arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare var po: Promise<{ fn(arg0: boolean, arg1: boolean, arg2: boolean): void; }>;
declare function before(): void;
declare function after(): void;
async function func(): Promise<void> {
    before();
    var b = (await po).fn(a, a, a);
    after();
}`,
        [],
      );
    });
    test("awaitClassExpression_es2017", async () => {
      await expectPass(
        `declare class C { }
declare var p: Promise<typeof C>;

async function func(): Promise<void> {
    class D extends (await p) {
    }
}`,
        [],
      );
    });
    test("awaitInheritedPromise_es2017", async () => {
      await expectPass(
        `interface A extends Promise<string> {}
declare var a: A;
async function f() {
    await a;
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration1_es2017", async () => {
      await expectPass(
        `async function foo(): Promise<void> {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration10_es2017", async () => {
      await expectError(
        `async function foo(a = await => await): Promise<void> {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration11_es2017", async () => {
      await expectPass(
        `async function await(): Promise<void> {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration12_es2017", async () => {
      await expectError(`var v = async function await(): Promise<void> { }`, []);
    });
    test("asyncFunctionDeclaration13_es2017", async () => {
      await expectPass(
        `async function foo(): Promise<void> {
   // Legal to use 'await' in a type context.
   var v: await;
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration14_es2017", async () => {
      await expectPass(
        `async function foo(): Promise<void> {
  return;
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration2_es2017", async () => {
      await expectPass(
        `function f(await) {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration3_es2017", async () => {
      await expectError(
        `function f(await = await) {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration4_es2017", async () => {
      await expectPass(
        `function await() {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration5_es2017", async () => {
      await expectError(
        `async function foo(await): Promise<void> {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration6_es2017", async () => {
      await expectError(
        `async function foo(a = await): Promise<void> {
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration7_es2017", async () => {
      await expectError(
        `async function bar(): Promise<void> {
  // 'await' here is an identifier, and not a yield expression.
  async function foo(a = await): Promise<void> {
  }
}`,
        [],
      );
    });
    test("asyncFunctionDeclaration8_es2017", async () => {
      await expectError(`var v = { [await]: foo }`, []);
    });
    test("asyncFunctionDeclaration9_es2017", async () => {
      await expectError(
        `async function foo(): Promise<void> {
  var v = { [await]: foo }
}`,
        [],
      );
    });
  });
});
