# Interop runtime AST identity boundary

The single-output, scope-hoisted production route owns its interop body as a
primary AST module. This closes that body's raw-template binding/scope boundary;
it does not close the complete A-plan in #4819, #5954, or #6193.

## Creation and activation

`runtime_interop_ast.build` selects the self-contained runtime source, creates
strict directive/body AST nodes, fixes the final program root, then runs one
initial semantic analysis. Expression arrows receive real block/return nodes
before scopes and references exist. Directives stay inside helper functions;
they do not make a bundled sloppy CJS module strict.

The producer records each helper's binding, declarator and initializer NodeIndex,
SID and ScopeId. Its ten public export bindings publish those already-created
identities. The graph-only provider record also owns the program root and
semantic owner token. It is not serialized or recovered from output spellings.
Consumers verify the same owner, root, structural tuples, scope and export slots.
The normal module cache reuses source modules; the provider receives a fresh
primary analysis and owner for each build.

Candidate insertion precedes Linker/TreeShaker allocation and creates no entry
root. After tree-shaking, included consumers add dependency edges and exact SID
seeds. Statement reachability follows the ordinary semantic reference edges.
Only toESM demand emits eight global helpers and ten locals; wrapper demand emits
ten helpers and fourteen locals. The unused group still has genuine AST nodes
and scopes, but is not emitted or initialized. Unused value imports preserve
source evaluation without constructing an interop namespace.

The provider's ordinary LinkingMetadata/Codegen output occupies the existing
preamble position before user dependency execution. Raw interop helper/internal
rows are not created alongside it. Split, preserve-modules, development and
scope-hoist-off routes still use their existing typed raw bodies and remain work
for later conversion. CJS/ESM factories, require shim and HMR bodies are separate
remaining scope ownership boundaries.

## Remaining generated reference creation

The following consumers read exact provider identities for output names, but
still construct their final calls as output text. They do not yet own generated
callee Reference rows:

- `codegen/modules.zig`: import lowering through `LinkingMetadata.to_esm_name`.
- `linker/metadata.zig` and `linker/preamble_writer.zig`: CJS namespace/default
  materialization, final exports and wrapper/namespace helper calls.
- `emitter/chunks.zig`: `dynamicCjsNamespaceExpr` and
  `rewriteDynamicImportsSingleFile` after module codegen.

A semantic Reference contains a module-local SID. Do not insert a foreign
provider SID into a source module's local symbol table. Create an actual local
import/alias binding and node with the exact provider export target, then create
the actual callee node/reference in its source or wrapper ScopeId. Preserve the
original dynamic-import NodeIndex at parser/scanner creation; an import-record
span is not identity. Once resolution and liveness are known, extend the same
graph through SemanticEditor and make codegen consume those real nodes. A
separate reference ledger alongside the text path is not completion.

## Split/bootstrap constraint

Object descriptor caches are initialized in the existing output preamble. A
shared provider hoist can change observable ordering: a getter replacing
`Object.getOwnPropertyDescriptor` observes zero reads in the native/single-output
control, but the existing split route with a shared patch module and distinct
CJS dependencies observes one. Sharing the CJS dependency too observes zero.
Preserve output-instance initialization or fix this behavior explicitly with
runtime evidence; do not unconditional-root candidates to hide liveness or
bootstrap differences. Appending per-output AST modules also requires updating
TreeShaker/chunk arrays sized by ModuleIndex before their consumers run.
