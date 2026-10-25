# For-of cleanup scope creation

`rewriteForOf` creates actual wrapper, try body, catch clause/body and nested
finally bodies before creating their references. The source iteration ScopeId is
reparented below the actual try body and retained by the emitted for statement.
The iterable stays in the original loop initializer Scope; it is not relocated
into the wrapper. Its existing references and import provenance remain intact.

The catch binding belongs to its catch Scope, while reads/writes inside the catch
body use the body's own Scope. IteratorClose reads use the inner try body's Scope;
error rethrow reads use its finally body's Scope. Runtime helper creation selects
the actual loop Scope explicitly and restores the traversal cursor afterward.
Copied source loops and pending extraction use exact source ownership.

Independent producer tests inspect eleven source programs in four combinations:
ordinary/state-machine and original/copied nodes. Both traversal cursors are
intentionally stale. Actual owner kinds/parents, binding storage, reference SID,
read/write flags and source import provenance are inspected before output walks.
Sixteen compiled implementation mutants must be rejected, with restored controls.
Runtime comparisons cover ten inputs across ordinary/generator/async-generator
functions, CLI and public APIs. This slice does not remove later generator scope
moves or the remaining post-transform analyzer callers in #6193.
