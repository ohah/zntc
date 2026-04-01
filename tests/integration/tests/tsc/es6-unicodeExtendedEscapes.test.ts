import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/unicodeExtendedEscapes", () => {
  test("unicodeExtendedEscapesInRegularExpressions01", async () => {
    await expectPass(
      `// @target: es5,es6

var x = /\\u{0}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions02", async () => {
    await expectPass(
      `// @target: es5,es6

var x = /\\u{00}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions03", async () => {
    await expectPass(
      `// @target: es5,es6

var x = /\\u{0000}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions04", async () => {
    await expectPass(
      `// @target: es5,es6

var x = /\\u{00000000}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions05", async () => {
    await expectPass(
      `// @target: es5,es6

var x = /\\u{48}\\u{65}\\u{6c}\\u{6c}\\u{6f}\\u{20}\\u{77}\\u{6f}\\u{72}\\u{6c}\\u{64}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions06", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  1. Assert: 0 ≤ cp ≤ 0x10FFFF.
var x = /\\u{10FFFF}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions07", async () => {
    await expectError(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  1. Assert: 0 ≤ cp ≤ 0x10FFFF.
var x = /\\u{110000}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions08", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  2. If cp ≤ 65535, return cp.
// (FFFF == 65535)
var x = /\\u{FFFF}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions09", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  2. If cp ≤ 65535, return cp.
// (10000 == 65536)
var x = /\\u{10000}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions10", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  2. Let cu1 be floor((cp – 65536) / 1024) + 0xD800.
// Although we should just get back a single code point value of 0xD800,
// this is a useful edge-case test.
var x = /\\u{D800}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions11", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  2. Let cu2 be ((cp – 65536) modulo 1024) + 0xDC00.
// Although we should just get back a single code point value of 0xDC00,
// this is a useful edge-case test.
var x = /\\u{DC00}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions12", async () => {
    await expectError(
      `// @target: es5,es6

var x = /\\u{FFFFFFFF}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions13", async () => {
    await expectPass(
      `// @target: es5,es6

var x = /\\u{DDDDD}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions14", async () => {
    await expectError(
      `// @target: es5,es6

// Shouldn't work, negatives are not allowed.
var x = /\\u{-DDDD}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions15", async () => {
    await expectPass(
      `// @target: es5,es6

var x = /\\u{abcd}\\u{ef12}\\u{3456}\\u{7890}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions16", async () => {
    await expectPass(
      `// @target: es5,es6

var x = /\\u{ABCD}\\u{EF12}\\u{3456}\\u{7890}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions17", async () => {
    await expectError(
      `// @target: es5,es6

var x = /\\u{r}\\u{n}\\u{t}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions18", async () => {
    await expectPass(
      `// @target: es5,es6

var x = /\\u{65}\\u{65}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInRegularExpressions19", async () => {
    await expectError(
      `// @target: es5,es6

var x = /\\u{}/gu;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings01", async () => {
    await expectPass(
      `// @target: es5,es6

var x = "\\u{0}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings02", async () => {
    await expectPass(
      `// @target: es5,es6

var x = "\\u{00}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings03", async () => {
    await expectPass(
      `// @target: es5,es6

var x = "\\u{0000}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings04", async () => {
    await expectPass(
      `// @target: es5,es6

var x = "\\u{00000000}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings05", async () => {
    await expectPass(
      `// @target: es5,es6

var x = "\\u{48}\\u{65}\\u{6c}\\u{6c}\\u{6f}\\u{20}\\u{77}\\u{6f}\\u{72}\\u{6c}\\u{64}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings06", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  1. Assert: 0 ≤ cp ≤ 0x10FFFF.
var x = "\\u{10FFFF}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings07", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  1. Assert: 0 ≤ cp ≤ 0x10FFFF.
var x = "\\u{110000}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings08", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  2. If cp ≤ 65535, return cp.
// (FFFF == 65535)
var x = "\\u{FFFF}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings09", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  2. If cp ≤ 65535, return cp.
// (10000 == 65536)
var x = "\\u{10000}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings10", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  2. Let cu1 be floor((cp – 65536) / 1024) + 0xD800.
// Although we should just get back a single code point value of 0xD800,
// this is a useful edge-case test.
var x = "\\u{D800}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings11", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  2. Let cu2 be ((cp – 65536) modulo 1024) + 0xDC00.
// Although we should just get back a single code point value of 0xDC00,
// this is a useful edge-case test.
var x = "\\u{DC00}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings12", async () => {
    await expectPass(
      `// @target: es5,es6

var x = "\\u{FFFFFFFF}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings13", async () => {
    await expectPass(
      `// @target: es5,es6

var x = "\\u{DDDDD}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings14", async () => {
    await expectError(
      `// @target: es5,es6

// Shouldn't work, negatives are not allowed.
var x = "\\u{-DDDD}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings15", async () => {
    await expectPass(
      `// @target: es5,es6

var x = "\\u{abcd}\\u{ef12}\\u{3456}\\u{7890}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings16", async () => {
    await expectPass(
      `// @target: es5,es6

var x = "\\u{ABCD}\\u{EF12}\\u{3456}\\u{7890}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings17", async () => {
    await expectError(
      `// @target: es5,es6

var x = "\\u{r}\\u{n}\\u{t}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings18", async () => {
    await expectPass(
      `// @target: es5,es6

var x = "\\u{65}\\u{65}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings19", async () => {
    await expectError(
      `// @target: es5,es6

var x = "\\u{}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings20", async () => {
    await expectError(
      `// @target: es5,es6

var x = "\\u{";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings21", async () => {
    await expectError(
      `// @target: es5,es6

var x = "\\u{67";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings22", async () => {
    await expectError(
      `// @target: es5,es6

var x = "\\u{00000000000067";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings23", async () => {
    await expectPass(
      `// @target: es5,es6

var x = "\\u{00000000000067}";
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings24", async () => {
    await expectError(
      `// @target: es5,es6

var x = "\\u{00000000000067
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInStrings25", async () => {
    await expectError(
      `// @target: es5,es6

var x = "\\u{00000000000067}
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates01", async () => {
    await expectPass(
      `// @target: es5,es6

var x = \`\\u{0}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates02", async () => {
    await expectPass(
      `// @target: es5,es6

var x = \`\\u{00}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates03", async () => {
    await expectPass(
      `// @target: es5,es6

var x = \`\\u{0000}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates04", async () => {
    await expectPass(
      `// @target: es5,es6

var x = \`\\u{00000000}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates05", async () => {
    await expectPass(
      `// @target: es5,es6

var x = \`\\u{48}\\u{65}\\u{6c}\\u{6c}\\u{6f}\\u{20}\\u{77}\\u{6f}\\u{72}\\u{6c}\\u{64}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates06", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  1. Assert: 0 ≤ cp ≤ 0x10FFFF.
var x = \`\\u{10FFFF}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates07", async () => {
    await expectError(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  1. Assert: 0 ≤ cp ≤ 0x10FFFF.
var x = \`\\u{110000}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates08", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  2. If cp ≤ 65535, return cp.
// (FFFF == 65535)
var x = \`\\u{FFFF}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates09", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  2. If cp ≤ 65535, return cp.
// (10000 == 65536)
var x = \`\\u{10000}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates10", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  2. Let cu1 be floor((cp – 65536) / 1024) + 0xD800.
// Although we should just get back a single code point value of 0xD800,
// this is a useful edge-case test.
var x = \`\\u{D800}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates11", async () => {
    await expectPass(
      `// @target: es5,es6

// ES6 Spec - 10.1.1 Static Semantics: UTF16Encoding (cp)
//  2. Let cu2 be ((cp – 65536) modulo 1024) + 0xDC00.
// Although we should just get back a single code point value of 0xDC00,
// this is a useful edge-case test.
var x = \`\\u{DC00}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates12", async () => {
    await expectError(
      `// @target: es5,es6

var x = \`\\u{FFFFFFFF}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates13", async () => {
    await expectPass(
      `// @target: es5,es6

var x = \`\\u{DDDDD}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates14", async () => {
    await expectError(
      `// @target: es5,es6

// Shouldn't work, negatives are not allowed.
var x = \`\\u{-DDDD}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates15", async () => {
    await expectPass(
      `// @target: es5,es6

var x = \`\\u{abcd}\\u{ef12}\\u{3456}\\u{7890}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates16", async () => {
    await expectPass(
      `// @target: es5,es6

var x = \`\\u{ABCD}\\u{EF12}\\u{3456}\\u{7890}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates17", async () => {
    await expectError(
      `// @target: es5,es6

var x = \`\\u{r}\\u{n}\\u{t}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates18", async () => {
    await expectPass(
      `// @target: es5,es6

var x = \`\\u{65}\\u{65}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates19", async () => {
    await expectError(
      `// @target: es5,es6

var x = \`\\u{}\`;
`,
      [],
    );
  });
  test("unicodeExtendedEscapesInTemplates20", async () => {
    await expectPass(
      `// @target: es5,es6

var x = \`\\u{48}\\u{65}\\u{6c}\\u{6c}\\u{6f}\${\`\\u{20}\\u{020}\\u{0020}\\u{000020}\`}\\u{77}\\u{6f}\\u{72}\\u{6c}\\u{64}\`;
`,
      [],
    );
  });
});
