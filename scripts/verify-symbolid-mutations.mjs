import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const testBinary = path.join(root, "zig-out/bin/lib-unit-test");
const testFilterFor = (pr) => pr === 6029 ? "#6029 hostile" : "namespace hostile";
const files = {
  hoist: path.join(root, "src/transformer/transformer/semantic_edit.zig"),
  namespace: path.join(root, "src/bundler/linker/metadata.zig"),
};
const regions = {
  hoist: {
    start: "fn bindPendingHoistedTempReference(",
    end: "\nfn forgetPendingTempProducerReferences(",
  },
  namespace: {
    start: "fn importBindingLocalSemanticIndex(",
    end: "\n/// (#3975)",
  },
};

function fail(message) {
  throw new Error(message);
}

function replaceOnce(text, before, after, label) {
  const first = text.indexOf(before);
  if (first < 0 || text.indexOf(before, first + before.length) >= 0) {
    fail(label + ": expected exactly one source match");
  }
  return text.slice(0, first) + after + text.slice(first + before.length);
}

function editRegion(source, startMarker, endMarker, before, after, label) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  if (start < 0 || end < 0) fail(label + ": could not isolate source region");
  const region = source.slice(start, end);
  return source.slice(0, start) + replaceOnce(region, before, after, label) + source.slice(end);
}

function mutate(originals, mutant) {
  const changed = new Map(originals);
  const region = regions[mutant.file];
  changed.set(mutant.file, editRegion(
    originals.get(mutant.file),
    region.start,
    region.end,
    mutant.before,
    mutant.after,
    mutant.label,
  ));
  return changed;
}

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  return {
    status: result.status ?? 1,
    output: (result.stdout ?? "") + (result.stderr ?? ""),
  };
}

function tail(output) {
  return output.trim().split("\n").slice(-24).join("\n");
}

function writeSources(sources) {
  for (const [key, file] of Object.entries(files)) {
    writeFileSync(file, sources.get(key));
  }
}

function build(testFilter, label) {
  const result = run("zig", ["build", "test-bin", "-Dtest-filter=" + testFilter]);
  if (result.status !== 0) {
    fail(label + ": mutation did not compile:\n" + tail(result.output));
  }
}

function runTargetTest(expectPass, label) {
  const result = run(testBinary, []);
  if (expectPass && result.status !== 0) {
    fail(label + ": baseline hostile tests failed:\n" + result.output.trim());
  }
  if (!expectPass && result.status === 0) {
    fail(label + ": mutant escaped all hostile tests");
  }
  return result.output;
}

const mutants = [
  {
    pr: 6029, file: "hoist", label: "ignore transformer/editor SID disagreement",
    before: "if (transformer_symbol != null and editor_symbol != null and transformer_symbol.? != editor_symbol.?)",
    after: "if (false and transformer_symbol != null and editor_symbol != null and transformer_symbol.? != editor_symbol.?)",
  },
  {
    pr: 6029, file: "hoist", label: "ignore the requested producer SID",
    before: "if (known_symbol != null and known_symbol.? != @backingInt(symbol))",
    after: "if (false and known_symbol != null and known_symbol.? != @backingInt(symbol))",
  },
  {
    pr: 6029, file: "hoist", label: "accept an existing reference to another SID",
    before: "if (existing.symbol_id != symbol or !std.meta.eql(existing.flags, flags))",
    after: "if (!std.meta.eql(existing.flags, flags))",
  },
  {
    pr: 6029, file: "hoist", label: "accept existing reference with different read/write flags",
    before: "if (existing.symbol_id != symbol or !std.meta.eql(existing.flags, flags))",
    after: "if (existing.symbol_id != symbol)",
  },
  {
    pr: 6029, file: "hoist", label: "leave an existing reference in its old scope",
    before: "if (existing.scope_id != scope)",
    after: "if (false and existing.scope_id != scope)",
  },
  {
    pr: 6029, file: "hoist", label: "append a duplicate for an existing reference",
    before: "editor.relocateReference(\n                node,\n                scope,\n                symbol,\n                existing.stmt_idx,\n                existing.scope_stmt_idx,\n            ) catch |err| return editError(err);",
    after: "editor.addCopiedReference(\n                node,\n                symbol,\n                scope,\n                flags,\n                existing.stmt_idx,\n                existing.scope_stmt_idx,\n            ) catch |err| return editError(err);",
  },
  {
    pr: 6029, file: "hoist", label: "use addReference for an already copied SID",
    before: "editor.addCopiedReference(node, symbol, scope, flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);",
    after: "editor.addReference(node, symbol, scope, flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);",
  },
  {
    pr: 6029, file: "hoist", label: "omit a reference when the node has no known SID",
    before: "editor.addReference(node, symbol, scope, flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);",
    after: "if (false) editor.addReference(node, symbol, scope, flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);",
  },
  {
    pr: 6029, file: "hoist", label: "skip writing the assigned SID to the transformer map",
    before: "if (transformer_symbol == null) try setSymbolId(self, node, symbol);",
    after: "if (false) try setSymbolId(self, node, symbol);",
  },
  {
    pr: 6029, file: "hoist", label: "swallow invalid-reference relocation errors",
    before: "editor.relocateReference(\n                node,\n                scope,\n                symbol,\n                existing.stmt_idx,\n                existing.scope_stmt_idx,\n            ) catch |err| return editError(err);",
    after: "editor.relocateReference(\n                node,\n                scope,\n                symbol,\n                existing.stmt_idx,\n                existing.scope_stmt_idx,\n            ) catch {};",
  },
  {
    pr: 6106, file: "namespace", label: "always resolve through the spelling map",
    before: "if (ib.local_symbol.isValid()) {",
    after: "if (false) {",
  },
  {
    pr: 6106, file: "namespace", label: "accept a valid SymbolRef from another module",
    before: "if (ib.local_symbol.moduleIndex() != ModuleIndex.fromUsize(module_index)) return null;",
    after: "if (false) return null;",
  },
  {
    pr: 6106, file: "namespace", label: "reject valid local SymbolRefs as foreign",
    before: "ib.local_symbol.moduleIndex() != ModuleIndex.fromUsize(module_index)",
    after: "ib.local_symbol.moduleIndex() == ModuleIndex.fromUsize(module_index)",
  },
  {
    pr: 6106, file: "namespace", label: "select the next semantic symbol slot",
    before: "return ib.local_symbol.semanticIndex();",
    after: "return (ib.local_symbol.semanticIndex() orelse return null) + 1;",
  },
  {
    pr: 6106, file: "namespace", label: "drop fallback for invalid SymbolRefs",
    before: "const scope_index = module_scope.get(ib.local_name) orelse return null;\n    return @intCast(scope_index);",
    after: "return null;",
  },
  {
    pr: 6106, file: "namespace", label: "use the exported name for fallback lookup",
    before: "module_scope.get(ib.local_name)",
    after: "module_scope.get(ib.imported_name)",
  },
  {
    pr: 6106, file: "namespace", label: "treat a valid alias as an invalid SymbolRef",
    before: "if (ib.local_symbol.isValid()) {",
    after: "if (ib.local_symbol.semanticIndex() != null) {",
  },
  {
    pr: 6106, file: "namespace", label: "compare against the next module index",
    before: "ModuleIndex.fromUsize(module_index)",
    after: "ModuleIndex.fromUsize(module_index + 1)",
  },
  {
    pr: 6106, file: "namespace", label: "fallback to spelling for a foreign valid SymbolRef",
    before: "if (ib.local_symbol.moduleIndex() != ModuleIndex.fromUsize(module_index)) return null;",
    after: "if (ib.local_symbol.moduleIndex() != ModuleIndex.fromUsize(module_index)) return @intCast(module_scope.get(ib.local_name) orelse return null);",
  },
  {
    pr: 6106, file: "namespace", label: "use spelling map even for a valid local SymbolRef",
    before: "return ib.local_symbol.semanticIndex();",
    after: "return @intCast(module_scope.get(ib.local_name) orelse return null);",
  },
];

if (mutants.filter((mutant) => mutant.pr === 6029).length !== 10) fail("PR #6029 must have ten mutants");
if (mutants.filter((mutant) => mutant.pr === 6106).length !== 10) fail("PR #6106 must have ten mutants");

const originals = new Map(Object.entries(files).map(([key, file]) => [key, readFileSync(file, "utf8")]));

if (process.argv.includes("--check-only")) {
  for (const [index, mutant] of mutants.entries()) {
    mutate(originals, mutant);
    console.log("READY " + (index + 1) + "/20: PR #" + mutant.pr + " " + mutant.label);
  }
} else {
  try {
    build(testFilterFor(6029), "baseline PR #6029");
    runTargetTest(true, "baseline PR #6029");
    build(testFilterFor(6106), "baseline PR #6106");
    runTargetTest(true, "baseline PR #6106");
    console.log("BASELINE PASS: PR #6029 and PR #6106 hostile tests");

    for (const [index, mutant] of mutants.entries()) {
      writeSources(mutate(originals, mutant));
      try {
        build(testFilterFor(mutant.pr), "mutant " + (index + 1));
        runTargetTest(false, "mutant " + (index + 1));
        const familyIndex = mutants.slice(0, index + 1).filter((entry) => entry.pr === mutant.pr).length;
        const familyTotal = mutants.filter((entry) => entry.pr === mutant.pr).length;
        console.log("KILLED PR #" + mutant.pr + " " + familyIndex + "/" + familyTotal + ": " + mutant.label);
      } finally {
        writeSources(originals);
      }
    }
    console.log("PR #6029 COMPILEABLE MUTANTS KILLED: 10/10");
    console.log("PR #6106 COMPILEABLE MUTANTS KILLED: 10/10");
  } finally {
    writeSources(originals);
  }
}
