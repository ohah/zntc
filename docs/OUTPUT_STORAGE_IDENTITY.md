# Output storage identity

`bindOutputScopesAndReferences` no longer creates a new `SymbolId` to split
independent output storage, or substitutes an existing same-spelled var ID.
The producer must choose both identities before final placement. An invalid
producer now fails the semantic-edit invariant instead of being repaired.

The checked implementation is also called directly by protocol tests. The
production entry preserves the existing invalid-semantic-edit panic contract.

All reachable source binding counterparts participate in validation, including
unchanged source bindings. Otherwise a copied source ID could appear to have
only one output location and steal the original declaration's identity.
Unchanged counterparts do not trigger new placement or scope bridging.

Groups validate the exact producer ID, target scope, symbol kind and identifier
StringValue. Unicode escapes and decoded plugin var redeclarations can describe
the same storage. An explicit ID-keyed output alias can also describe that same
storage; it is validated against the producer's name and never used to select an
ID by spelling. Different same-scope names cannot silently share an ID.

Actual sloppy Annex B block function aliases retain their shared var identity.
The existing source name or explicit ID-keyed alias must match too: merely being
a sloppy block function in the same var scope cannot legitimize an unrelated
copied ID. Decoding has no fixed-size identifier limit. Unrelated variable
declarations do not qualify for this exception. Resource/try-block var placement cannot cross
a function's var boundary.

## Validation boundaries

Ten source contexts cover global var/let/const, functions, arrows, anonymous
functions, async functions, generators, object methods/getters, class
methods/static methods and non-simple parameters. Each runs a valid
creation-time identity case, an invalid copied ID in a different storage scope,
and a different same-scope name with that ID. Four var contexts also move independent storage into an occupied var scope.
The tests inspect binding IDs, actual Reference rows, reference scopes,
symbol/scope counts, exact coverage and ID-keyed codegen names. Existing NAPI
plugin tests cover legitimate var redeclarations, including Unicode escapes.
An independent review added an unrelated Annex B function negative, plus ordinary,
escaped, ID-keyed alias and long equivalent-spelling positive controls.

Before removing the legacy branches, an instrumented baseline observed no
late split or merge events in 7,459 unit tests and 7,248 CLI invocations of
the raw/minified downlevel oracles. That is a bounded execution census, not
proof that every supported producer already satisfies the full A plan.

Generated scope creation, scope relocation/bridging, copied-reference
registration and invisible-reference classification still remain in this
output walk. Other explicit producer split APIs also remain. Removing the
late storage-ID repair does not complete #4819, #5954 or #6193.
