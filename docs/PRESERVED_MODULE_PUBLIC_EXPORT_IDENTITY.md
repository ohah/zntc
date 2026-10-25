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

The synchronous PM ESM producer also owns default/namespace and bare-import
initialization. A mixed record keeps canonical value bindings alive while
separately marking eager initialization and lazy read calls. The legacy eager
preamble skips only work already owned by those actual calls. CJS and async/TLA
initializers retain their separate paths; this admission does not widen them.

Import bindings carry their actual declaration NodeIndex from construction:
parser scan batches, AST scanning and compiler import creation all publish it.
The planner checks the birth declaration, current source literal and actual
specifier/local anchor together. It does not repair an owner from names or spans.
A bare import has no local binding, so its known source literal must have exactly
one live bare-import owner.

An eagerly initialized namespace keeps its original source read SID and Scope,
and consumes the provider's exact namespace storage slot. The public getter and
final-export collector use the same source export-anchor SID relation. Member
calls keep their original AST receiver. For an owned re-export, namespace getters
read the live provider property instead of a legacy synthetic-default snapshot
or another initializer expression. A real source `export default value` or member
expression still owns its snapshot facade; named declaration defaults remain
live, including lowered named classes and chains of re-exports.

Owner-bound compiler imports retain the existing conservative persistent-store
eviction policy. Disk snapshots are taken before those process-local callsites
are constructed, and supported reloads construct fresh owners. This change does
not establish arbitrary cross-process foreign-owner reuse or close #4819.

Preserved import specifiers are calculated from the same output paths used by
the file writer, including root-level virtual helper files and nested source
files. A sanitized virtual chunk path is owned by the chunk graph and freed at
its teardown; ordinary source paths remain borrowed.

The regression matrix covers ten source forms in plain/minified output, native
Node comparisons, actual typed guard targets and reference scopes, unchanged
live-export identifier anchors, wrapper/public alias conflicts, and output-path
controls with and without a preserve-modules root. Separate mutation logs record
compile failures, real test failures and restored-source controls independently.

The eager-call matrix preserves an immutable ten-source input corpus and checks
plain/minified output against native Node. A direct producer probe compares
original source SID, Scope, reference flags, nested coordinates and declaration
owners before any output walk. It also checks real program-call target uniqueness
and Scope0 statement coordinates. Reporter getter counts independently detect a
raw guard call left behind by another emitter. Mutable namespace barrels have
separate expression/member snapshot, named function/class, anonymous class and
multi-edge re-export controls.

The wrapped preserve-modules CJS `output.exports = "named"` writer publishes the
final-export public-key ledger through the module's validated namespace storage
identity. It does not snapshot `FinalExportEntry.local`: a re-export entry may
still contain a legacy materialization expression while the real namespace
already owns the live provider getter. Namespace getters preserve named default
declaration updates and expression/member default snapshot storage separately.
Quoted ModuleExportName aliases remain JS literals; unquoted identifier strings
are escaped for a property key. Transport aliases are deduplicated against the
same public ledger. Guarded source import evaluation uses the same actual local
import references and foreign guard/initializer roles as ESM output.

The additional named-mode tests include namespace call/tag receivers, nested
same-name decoys, wrapper-name/public-alias conflicts, string public keys, direct
public re-export getters and renderer allocation failures. The exact source
SID/Scope/reference/declaration-owner comparison runs before output for CJS too.
This named-mode slice does not change `auto`, `default` or `none` mode policy.
Separate baseline/candidate artifacts preserve existing failures in `auto` and
`default`, including missing mixed/default-mode diagnostics; those public API
paths remain mandatory follow-up work.
