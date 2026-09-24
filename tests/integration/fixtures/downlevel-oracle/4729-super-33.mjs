function f() {
  const o = {
    __proto__: {
      m() {
        return arguments.length;
      },
    },
    c: arguments.length,
    n() {
      return super.m(1, 2);
    },
  };
  return o.c + ':' + o.n();
}
console.log(f(9, 9, 9));
