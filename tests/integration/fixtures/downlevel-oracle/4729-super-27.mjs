let hit = 0;
const f = () => ({
  __proto__: {
    m() {
      return ++hit;
    },
  },
  n() {
    return super.m();
  },
});
const a = f();
f();
console.log(a.n(), a.n());
