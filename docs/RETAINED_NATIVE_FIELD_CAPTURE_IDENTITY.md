# Retained native field capture (work in progress)

Moved constructor fields are covered separately by `NATIVE_FIELD_CAPTURE_IDENTITY.md`.
This change keeps native fields in their initializer environment. Before lowering
an arrow, its producer creates a factory parameter and function scope. Original
lexical-this AST handles select the operation to replace, and each replacement
reference is born with that exact parameter SID and its actual reference scope.
The lowered function retains the original arrow scope inside the factory.

Computed field names use primitive PropertyKey cells. Keys evaluate and coerce
once at their original key header. The field factory receives the cell value in
an exact parameter and restores native NamedEvaluation with a computed object
property, including Symbol and `__proto__` keys. It does not infer identities
from the key spelling.

An expression proved to run once in its enclosing function/module activation
uses that activation's ordinary temp hoister. An opaque producer ID carries the
exact reserved SID into the actual declaration; no declaration is inserted into
an argument or array list. Original scope-owner provenance identifies copied
class sites. The proof also covers nested blocks, catch and switch regions.

Loop bodies publish their lexical key cells before closure analysis. This
includes an explicit block/scope producer for an unbraced body. The existing
per-iteration function then owns the storage when block scoping is lowered.
When native block scoping is retained, the actual loop body owns the lexical
cells directly. Await-bearing extracted bodies use a
synchronous generator and an outer driver that awaits only source suspensions;
finishing an iteration adds no Promise wait. Rejections return through the
iterator's throw method, preserving source catch/finally and control-flow signals.
Native generator helpers use their actual function owner and visit the body in
the original capture frame before acquiring an arguments environment.

Collected native class declarations hand their outer binding to actual wrapper
storage while an inner class-expression binding retains the source class-self
SID. ES5 class lowering keeps its separate existing producer. Other repeated
sites still use a per-evaluation wrapper; those boundaries require further
validation before publication.

Super reads use the known class-self SID and the current home-object prototype,
and receiver reads use the factory's exact this parameter. Getter-method calls
use the same receiver for the getter and the returned callable. The initial
inferred-class binding producer preserves its observable name flag at birth.

The semantic-less low-level API is separate: it creates no semantic identities
and uses its existing symbolic output-name mechanism. Its caller must emit the
runtime helpers requested by the transformer.

## Pending validation and composition

This is a local, unpublished implementation checkpoint, not #4819 completion.
The native-derived constructor fix is merged separately and still needs composed
validation here. Engine-retained fields that call an earlier body closure inside
`super()` have a separate earlier-initialization requirement.

The composed local snapshot checks seventy-three source inputs in plain/minified
output: all 146 native comparisons now pass after the generator-function-cell
and live-arguments dependencies are composed. Before the latter dependency,
the native-generator mutable-arguments input failed in both modes. The factory
binding/reference birth probe and semantic-less controls also pass (23 selected
unit tests), and the separate loop-key birth probe passes across eight profiles
(21 selected unit tests). These are local composed results, not merged-main or
final public-API/cache validation of this feature.

The callback producer moves exact reference rows only after its hoisted storage
is bound; source lexical storage is handed to the actual wrapper declaration.
Driver storage, dynamic eval/with, partial capability combinations, wrapped class
declaration block-scoping, cache/import/export boundaries, final public API
oracles, final-state implementation mutants and normal push checks remain due.
The generator dependency's bundled sloppy Annex B alias spelling regression
was repaired with canonical storage carriers in #6355. Its required broader
oracle then exposed a separate bundled using-for-await publication-authority
regression; that main regression is being repaired independently. Neither is
covered by the direct-transpile field matrix above. Native non-simple
arguments environments and captured IIFE argument lifetimes remain separate
uncompleted obligations of the arguments dependency.

The separate constructor callback regression now has eleven native inputs in
plain/minified output. The last frozen run failed ten of those twenty-two comparisons: callbacks run by
native fields, replacement super objects, fields that throw, reentrant
construction, and a failed construction followed by a successful one. The
before/after-super, inferred function/class-name, and native-parameter
super-call reentrancy controls pass. A first production timing bridge now passes
all twenty-two comparisons. It prepares the source body scope and function cells
before visiting, publishes native this at the first retained field, and probes
source try bodies before catch/finally entry. The first implementation is gated
to simple parameters and excludes decorators, lowered private members, accessors,
deferred super and computed anonymous values without an existing key cell.
The program assembly now publishes statement coordinates while retaining each
recorded SID and Scope. An independent parent-map check passes before the generic
output walker; separate SID, Scope, stmt, scope-stmt and missing-tuple corruptions
are rejected, and the restored graph passes. Explicit name preservation controls
also pass in sixteen native comparisons. Broader runtime/API/cache validation,
remaining capability combinations and final implementation mutants remain due.
Handwritten
parameter-environment prototypes match two native reentry/private-brand examples;
they do not establish complete FDI, naming, scope, eval or target support.

The proposed activation protocol has four additional explicit native comparisons:
a callback run by a field, a throwing field followed by a destructuring catch
parameter, a private-brand failure before the first field, and nested construction.
All four match in Node. These controls assemble the bridge explicitly; they do
not exercise a production AST transform. The runtime template has no receiver
properties and detaches the completed activation's setter and previous frame.
The two runtime protocol tests pass in the 23-test focused Zig selection.

The constructor-body scope prerequisite has independently passed 21 focused unit
tests, including exact reference scopes and statement coordinates before an
output walker. The function-cell prerequisite now covers eleven native inputs.
Its exact declaration lifecycle removes rows by declaration_node_index and
preserves formal anchors and source-var rows, including multiple rows sharing
one anchor. The composed scope, function-cell and runtime prerequisites pass a
25-test focused selection on the main62a base. The 73-input field matrix also
passes all 146 native comparisons on that base and again after the timing and
coordinate producers are composed on main6e17. These prerequisites have a
production constructor-bridge caller in the current WIP snapshot.

Moved private initializers use a separate actual-constructor placement owner.
Their receiver factory and field new-target role restore twenty-two native
comparisons, while the independent combined selection passes 59 tests without an
extra test-only publication call. Private sibling-method references record their
known mapping SID and actual use Scope at creation; a program prefix shifts only
existing-row coordinates. A bounded insertion producer now preserves the
completion value of one actual native super site, initializes its exact compiler
receiver alias before the fields, and runs field initialization before a user
assignment setter. Zero-site derived constructors keep their object-return path.
Seven inputs pass fourteen native comparisons and independent pre-walker checks,
including five tuple corruptions and restoration per input. Three multi-site
inputs still fail six native comparisons; initializer ASTs are not shared across
sites.

Type-only constructor formal wrappers now retain the original binding SID for
function-cell storage. Parameter-property reads use fresh reference nodes for
that same SID. Typed, optional and public-property controls match native output
in both minification modes; the property case also passes the independent
pre-walker check. Ten formal-shape controls keep defaults, destructuring and rest
outside this simple-formal path. The combined constructor selection passes 38
tests; this does not cover the remaining multi-site failures. The separate
inner-with capture selection passes 24 tests using exact live-cell and native
arguments-engine identities rather than the obsolete pending-capture channel.
