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

The current runtime matrix has seventy-three inputs, each checked in plain/minified
output. The complete matrix is not passing: mutable arguments reads differ from
native output, and the loop function-declaration identity case aborts during
exact reference relocation. These failures remain required work. It covers source await ordering, rejection/finally, abrupt loop flow,
nested/unbraced loops and a native-generator partial profile. A separate probe
checks function-hoisted key storage before the final output walk. A loop-specific probe checks storage and references before the final walk
across eight source/profile combinations, including retained block scoping and
native generator capability combinations.
The callback producer moves exact reference rows only after its hoisted storage
is bound; source lexical storage is handed to the actual wrapper declaration.
Driver storage still needs its own complete producer-boundary probes.

Mutable source arguments, dynamic eval/with, partial capability combinations,
external wrapped class declaration block-scoping, cache/import/export boundaries,
final public API oracles, compileable implementation mutants and normal push
checks remain due. In particular, a capture snapshot cannot establish mutable
arguments-binding semantics across a suspension.

The separate constructor callback regression now has eleven native inputs in
plain/minified output. Ten of those twenty-two comparisons fail: callbacks run by
native fields, replacement super objects, fields that throw, reentrant
construction, and a failed construction followed by a successful one. The
before/after-super, inferred function/class-name, and native-parameter
super-call reentrancy controls pass. The test
remains failing until the native-field timing producer is implemented.
