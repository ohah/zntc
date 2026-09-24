async function f() {
  for (let i = 0; i < 2; i++) {
    await 0;
    const o = {
      __proto__: {
        m() {
          return i;
        },
      },
      n() {
        return super.m();
      },
    };
    setTimeout(() => console.log(o.n()));
  }
}
f();
