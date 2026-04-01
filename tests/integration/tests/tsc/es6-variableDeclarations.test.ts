import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/variableDeclarations", () => {
  test("VariableDeclaration1_es6", async () => {
    await expectError(`const`, []);
  });
  test("VariableDeclaration10_es6", async () => {
    await expectPass(`let a: number = 1`, []);
  });
  test("VariableDeclaration11_es6", async () => {
    await expectError(
      `"use strict";
let`,
      [],
    );
  });
  test("VariableDeclaration12_es6", async () => {
    await expectPass(
      `
let
x`,
      [],
    );
  });
  test("VariableDeclaration13_es6", async () => {
    await expectError(
      `
// An ExpressionStatement cannot start with the two token sequence \`let [\` because
// that would make it ambiguous with a \`let\` LexicalDeclaration whose first LexicalBinding was an ArrayBindingPattern.
var let: any;
let[0] = 100;`,
      [],
    );
  });
  test("VariableDeclaration2_es6", async () => {
    await expectError(`const a`, []);
  });
  test("VariableDeclaration3_es6", async () => {
    await expectPass(`const a = 1`, []);
  });
  test("VariableDeclaration4_es6", async () => {
    await expectError(`const a: number`, []);
  });
  test("VariableDeclaration5_es6", async () => {
    await expectPass(`const a: number = 1`, []);
  });
  test("VariableDeclaration6_es6", async () => {
    await expectError(`let`, []);
  });
  test("VariableDeclaration7_es6", async () => {
    await expectPass(`let a`, []);
  });
  test("VariableDeclaration8_es6", async () => {
    await expectPass(`let a = 1`, []);
  });
  test("VariableDeclaration9_es6", async () => {
    await expectPass(`let a: number`, []);
  });
});
