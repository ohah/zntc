# Using cleanup block scopes

The using producer creates the try block before creating its `__using` calls,
then creates the catch body and finally block in their exact parent scopes.
The catch binding remains owned by the catch clause; its reads execute in the
catch body's block. Disposal state and helper References are registered in the
block where their expression executes.

When the producer inserts existing source statements into the try block, it
moves their direct References and lexical bindings by their existing IDs.
Nested source closures keep their ScopeIds and move their lexical frontier.
Program/ES5 var storage keeps its existing var-lowering protocol. No name lookup
selects a replacement identity, and the generic final walk does not create
these cleanup block scopes.

The direct producer test executes twelve source-owner contexts before visiting or
finishing the transformed tree. It checks all four new scope owners/parents,
three cleanup bodies' actual References, the catch declaration anchor, original
binding IDs, nested closure parents, direct/nested import provenance and exact
symbol/scope counts. A baseline run fails all twelve contexts because the try block owner is missing.

The CLI runtime matrix keeps 240 native comparisons: ten inputs, six targets,
standalone/bundle and plain/minified output. During validation, a native ESNext
bundle/minified control exposed an existing purity bug that dropped disposal.
That separate defect was fixed in #6280. Its original comparison is retained
here as an ordinary passing test, with no expected-failure or skip marker.
The initial reproduction remains in
`/tmp/zntc-using-native-minify-oracle/results.json`.

Other generated loop/wrapper scopes and state-machine relocation remain
separate producer boundaries. This change does not complete the whole output
scope walk or #4819/#6193.

The native API adds 80 transpile/buildSync comparisons over ES5/ES2022,
plain/minified output and the same ten source contexts. Together the matrix
requires all 320 comparisons to match native output.
