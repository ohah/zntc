# Preserve-modules public export ownership

A wrapped preserve-modules ESM file must publish its source public exports as
well as the internal initializer/namespace handles used by sibling files. The
wrapper's namespace getters alone do not create native ESM exports.

The module emitter renders `LinkingMetadata.final_export_entries` through the
existing ESM renderer. The cross-chunk writer keeps additional transport aliases,
but removes keys already published by that public ledger. It compares the actual
cross-chunk output alias, not the source export spelling. This distinction keeps
helper transport exports such as `__classCallCheck$1` available. Flattened
export-star keys use the same final-export ledger.

Generated wrapper names reserve source public aliases before their exact
synthetic symbols are created. A source `export { value as init_entry }` therefore
does not collide with the internal initializer export. This is output spelling
selection at creation; consumers still use the existing module and SymbolId.

Preserve-modules installs the initially analyzed guard provider for real source
calls without creating an entry bootstrap artifact. Existing lazy named reads
retain their actual ScopeId and typed guard/initializer foreign edges. A live
local export of a supported named import uses an eager Scope0 call instead; its
export specifier stays an identifier with the original local SymbolId.
`guarded_eager_init_lowered` transfers evaluation ownership only. The original
import record remains available to canonical value naming; `callsite_lowered`
would incorrectly suppress that consumer too.

This eager extension admits records consisting of supported live exported named
bindings. Mixed lazy/eager binding records, default/namespace imports and other
legacy raw-prefix callers are not newly admitted here. Owner-bound compiler
imports retain the existing conservative cache eviction policy. This change does
not establish cross-process foreign-owner reuse or close #4819.

Preserved import specifiers are calculated from the same output paths used by
the file writer, including root-level virtual helper files and nested source
files. A sanitized virtual chunk path is owned by the chunk graph and freed at
its teardown; ordinary source paths remain borrowed.

The regression matrix covers ten source forms in plain/minified output, native
Node comparisons, actual typed guard targets and reference scopes, unchanged
live-export identifier anchors, wrapper/public alias conflicts, and output-path
controls with and without a preserve-modules root. Separate mutation logs record
compile failures, real test failures and restored-source controls independently.
