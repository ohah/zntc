let hit = 0;
const fLong = () => ({
  __proto__: {
    m() {
      return ++hit;
    },
  },
  n() {
    return super.m();
  },
});
const aLong = fLong();
fLong();
console.log(aLong.n(), aLong.n());
