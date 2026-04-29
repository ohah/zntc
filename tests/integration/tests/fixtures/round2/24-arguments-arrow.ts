function outer() {
  const arrow = () => arguments.length;
  function inner() { return arguments.length; }
  return [arrow(), inner(99, 100)];
}
console.log((outer as any)(1, 2, 3));
