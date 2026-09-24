const pLong = { x: 5 };
const oLong = {
  __proto__: pLong,
  get g() {
    return super.x;
  },
};
console.log(oLong.g);
