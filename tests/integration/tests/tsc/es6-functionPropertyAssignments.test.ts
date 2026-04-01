import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/functionPropertyAssignments", () => {
  test("FunctionPropertyAssignments1_es6", async () => {
    await expectPass(`var v = { *foo() { } }`, []);
  });
  test("FunctionPropertyAssignments2_es6", async () => {
    await expectError(`var v = { *() { } }`, []);
  });
  test("FunctionPropertyAssignments3_es6", async () => {
    await expectError(`var v = { *{ } }`, []);
  });
  test("FunctionPropertyAssignments4_es6", async () => {
    await expectError(`var v = { * }`, []);
  });
  test("FunctionPropertyAssignments5_es6", async () => {
    await expectPass(`var v = { *[foo()]() { } }`, []);
  });
  test("FunctionPropertyAssignments6_es6", async () => {
    await expectError(`var v = { *<T>() { } }`, []);
  });
});
