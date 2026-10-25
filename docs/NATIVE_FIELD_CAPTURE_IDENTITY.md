# Moved field initializer capture ownership

When a native class's fields move into a constructor, its field arrows must
capture that constructor's receiver. Merely switching the initializer's ScopeId
leaves a top-level class without a capture frame and aborts arrow lowering.
Using an enclosing function frame instead captures the wrong receiver.

The existing constructor plan now carries a borrowed field-capture context.
Its first lexical `this` use creates one constructor-owned declaration and SID.
Every subsequent field or source-constructor body use attaches its Reference
immediately at its actual scope. Separate traversal frames share the exact
binding explicitly. Parameter environments and nested ordinary functions do
not borrow this body-local storage.

Constructor assembly places that declaration before field assignments and,
for derived constructors with a direct super call, after that call. The source
constructor's ordinary capture producer does not create a second declaration.
Both implicit constructor shells and existing constructor owners keep their
exact ScopeIds. The borrowed context is restored when each visit ends.

The private source checks compare native values and independently inspect the
output before generic binding/finalization: constructor storage, unique live
binding, reference SID, physical reference scope, and access flags. The cases
include both constructor orders, parameter/global collisions, nested/async
arrows, outer frames, replacement super objects and field new.target.

These checks cover moved initializers, including assign semantics and forced
field lowering with define semantics. Retained native fields have their own
initializer environment and remain a separate capture boundary. Other generic
capture finalizers and post-transform analyzers remain tracked by #4819/#6193;
this change does not close those issues.
