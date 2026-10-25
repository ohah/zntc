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

An expression evaluated once in a direct function/module body statement uses
that existing activation's storage. Original scope-owner provenance identifies
an inferred-class copy's source evaluation site. Other sites currently get a
per-evaluation wrapper. Source key expressions retain their original lexical
class scope. Generated declaration statements have zero-length anchors.

Super reads use the known class-self SID and the current home-object prototype,
and receiver reads use the factory's exact this parameter. Getter-method calls
use the same receiver for the getter and the returned callable. The initial
inferred-class binding producer preserves its observable name flag at birth.

The semantic-less low-level API is separate: it creates no semantic identities
and uses its existing symbolic output-name mechanism. Its caller must emit the
runtime helpers requested by the transformer.

## Pending validation and composition

This is a local, unpublished implementation checkpoint, not #4819 completion.
The native-derived constructor body's lazy-this lifetime must be composed with
the separate constructor fix; eager body alias initialization still fails two
runtime comparisons. Engine-retained fields that call an earlier body closure
inside `super()` have a separate earlier-initialization requirement.

The direct-body placement proof does not cover arbitrary await-bearing keys in
loops and nested lexical regions. These need actual source-context validation,
not an extra async function that changes promise scheduling. The external slot
of a wrapped class declaration must also satisfy the target's block-scoping
contract. Cache, import/export, private/with/eval boundaries, final public API
oracles, compileable implementation mutants and normal push checks remain due.
