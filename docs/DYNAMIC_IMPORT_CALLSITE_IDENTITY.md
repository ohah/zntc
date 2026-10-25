# Dynamic import callsite identity

This closes the initially supported single-output, resolved, one-argument
`import("literal")` callsite creation path. It does not close #4819, #5954 or the
full A-plan. Static CJS import materialization, wrappers, other output modes,
native import boundaries and cross-owner cache reuse remain separate work.

## Creation and ownership

1. Both the inline parser scan and the standalone import scanner capture the
   actual import-expression `NodeIndex` when the expression is created. A source
   span or another occurrence of its specifier cannot select its identity.
2. Initial semantic analysis records expression use provenance separately from
   `scope_owner_map`: its actual `ScopeId`, initial source expression and source
   `with` environment. Expressions do not claim to own lexical scopes.
3. Explicit clone and generic visitor propagation preserve the source
   expression. The strict class initializer factory and lowered constructor default producers explicitly relocate direct
   expression scopes. Nested functions keep their ScopeId and reparent their
   lexical root. Fresh semantic analysis of the same append-only AST preserves
   only that original expression handle, while taking ScopeIds from the new
   owner. The output-scope walk reconciles existing provenance and rejects
   a reachable import expression that lost its creation provenance.
4. Before linker/shaker arrays are sized, a disconnected compiler-owned module
   is parsed and initially analyzed once. Its ordinary function owns the
   `Promise.resolve().then(callback)` body and a real parameter/reference scope.
   The body contains an actual `"use strict"` directive. No runtime name scan,
   external-reference marker or second semantic analysis chooses its binding.
5. After resolution and tree-shaking, only live consumers activate this module.
   Parser speculation rolls back its inline records, bindings and scan flags;
   a discarded parse cannot publish an anchor for a different live creation.
   Pruned import records do not stand for another live expression merely
   because their specifier or former span matches it.
   SemanticEditor appends actual source-local import declarations, binding SIDs,
   resolved import records and exact foreign SID/owner edges. Real callback
   function owners use the original expression's actual use scope as parent.
   Actual callee references use local SIDs; foreign SIDs never enter a local
   Reference row. The same AST and semantic graph are consumed by codegen.
6. Before finish, producer handles validate callee nodes/Reference rows, callback
   ownership/parents and foreign owner identities. The generic exact-scope
   calculation validates expression provenance against real AST lexical owners,
   including parameter/body boundaries. The codegen symbol-ID cache receives
   the same final semantic array. Converted records bypass text rewriting.

The scheduler reads Promise when a live import executes, not during bootstrap.
Its exact graph-wide output identity is planned before ordinary source renames.
It avoids source parameter/global spellings and statically visible literal-eval
identifiers (including decoded names, concatenation and bounded templates).
Inactive candidates contribute neither output bindings nor free Promise name
reservations, so an unused candidate cannot change source eval observations.
Interop object descriptor caches retain their existing pre-dependency emission
position. Provider activation adds typed dependencies and exact statement seeds;
it does not create an unconditional entry root.

## Cache boundary

Semantic codec v20 persists expression provenance; the semantic owner token
remains process-local and is never serialized. Constructor, codec and direct
semantic handoffs carry the same provenance contract.

The generated consumer AST captures a particular provider owner. Persistent
module-store transfer therefore evicts that consumer rather than guessing a
replacement SID after graph reconstruction. The current three-build control
reparses two source modules cold and one consumer on each unchanged warm build.
There is no claim of a zero-parse warm build or completed owner-linked cache
reuse. Unaffected modules still use their ordinary cache.

The existing mutable cross-module reference-count population can change
minified spelling across a persistent-store rebuild. Non-minified byte controls
and actual minified cold/warm execution are distinct checks. Per-build ownership
of these graph-derived counts and exact foreign-handle rebinding across cached
consumer owners remain required followups.

## Explicit native and legacy boundaries

- Actual source `with` ObjectEnvironments retain the existing text-lowered
  route. Plain objects, prototype properties, Proxy `has` and
  `Symbol.unscopables` controls remain in the test denominator. A new scheduler
  identifier inside `with` was observed to be intercepted even when its lexical
  SID was exact. Changing its spelling would hide the semantic problem.
- This gate follows the initial expression's actual `with` environment, not
  `subtree_has_with`, `blocksMangling` or direct eval. Sibling expressions outside
  `with` and source parameters observed by direct eval use the actual AST path.
- Import expressions with a second options/attributes argument retain the
  existing native passthrough. The old `importCallSpanAt` already rejected that
  form; its option/getter evaluation must not be discarded by AST lowering.
- Nonliteral/unresolved/external imports, split/preserve/development and
  scope-hoist-off routes keep their existing policies.

The legacy `with` route still has the old Promise/interop/require dynamic lookup
limitations. A source `with` scope contract that keeps generated references out
of ObjectEnvironment lookup is required for full A completion. It is not an
exception that removes those callsites from the final denominator. Opaque eval
whose program comes from runtime input can still observe or assign generated
output bindings; reserving statically visible tokens does not solve that scope
isolation contract. It remains required work, distinct from old raw Promise and
interop/require lookup limitations.

## Remaining caller work

`codegen/modules.zig`, `linker/metadata.zig` and `linker/preamble_writer.zig` still
materialize static CJS imports and wrapper/export accesses as text. Namespace
and default imports need a one-time real variable initializer while preserving
namespace identity. Named imports need actual member/callee AST references while
preserving live property reads. Wrapped ESM storage and initialization ordering
must use the same producer handoff. These consumers follow this dynamic-import
slice; they are not completed by its Reference rows.

## Validation

The original raw-callsite route fails the ten-context structural regression:
none of its ten consumers has the actual scheduler/callback graph. The new
route passes all ten, including distinct parameter/body scopes, strict factories,
source helper decoys and ESM namespace handles. Ten malformed-handle controls
reject scope, owner, node and local/foreign SID corruption before finish.

Ten independently compiled mutations are detected: lost clone source origin,
guessed callback parent, omitted callee Reference, omitted callback owner,
wrong valid scheduler SID, stale codegen SID array, omitted provider owner guard,
omitted foreign owner guard, omitted actual AST use-scope check and dropped
serialized provenance. The unmodified snapshot passes after restoration.

The pre-rebase full Debug suite passes 7,469 tests; the final integrated suite
also passes through the normal pre-push hook. ReleaseFast CLI execution passes
120 combinations (ten sources, four target/minification modes and three output
formats). Runtime tests separately exercise literal eval tokens, live/dead
Promise getter timing, microtask order, bootstrap caches, source CJS/UMD sloppy
environments, native option evaluation, with-environment legacy controls and
persistent-cache execution. The final ReleaseFast NAPI run executes 217 tests: 208 pass and nine retained
baseline TODOs fail as expected. These controls do not turn the explicit remaining
boundaries above into completed scope contracts. Normal formatting, full test,
oxlint and oxfmt pre-push checks pass without bypass flags.

Five additional runtime combinations remain executable TODO controls because
both the prior provider-only compiler and this slice fail them: full minification
removes a source binding read only by literal eval (two modes), syntax minification
removes an eval-observed source Promise binding (one mode), and full minification
removes the options binding read by a native import's second argument (two modes).
These are baseline DCE/statement-reference defects, not passing controls. They
remain in the denominator and require separate repairs; this PR does not claim
complete literal-eval or native-options support.

Actual top-level await is a separate boundary from an async importing function.
For a dependency that awaits a timer before exporting 42, native import returns
42. The prior and current compilers both return 42 for CJS output, but return
undefined for ESM/IIFE output (plain and minified). Those four combinations remain
executable TODOs, with two passing CJS controls. The callback's current
`(init(), namespace)` body does not await async initialization; preserving the
async init Promise chain remains required after static caller conversion.
