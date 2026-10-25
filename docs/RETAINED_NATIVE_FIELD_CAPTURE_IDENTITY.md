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
The generator dependency has separately exposed a bundled sloppy Annex B alias
spelling regression during fair native/baseline/candidate validation; that result
is not covered by the direct-transpile field matrix above. Native non-simple
arguments environments and captured IIFE argument lifetimes remain separate
uncompleted obligations of the arguments dependency.

The separate constructor callback regression now has eleven native inputs in
plain/minified output. The last frozen run failed ten of those twenty-two comparisons: callbacks run by
native fields, replacement super objects, fields that throw, reentrant
construction, and a failed construction followed by a successful one. The
before/after-super, inferred function/class-name, and native-parameter
super-call reentrancy controls pass. No native-field timing producer has been implemented here. Handwritten
parameter-environment prototypes match two native reentry/private-brand examples;
they do not establish complete FDI, naming, scope, eval or target support.
