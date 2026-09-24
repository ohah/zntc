async function f() {
  const r = [];
  for (var i = 0; i < 2; i++) {
    r.push({
      __proto__: { v: i },
      w: await i,
      get g() {
        return super.v;
      },
    });
  }
  return r.map((o) => o.g);
}
f().then((v) => console.log(v.join()));
