const p = { x: 5 };
const o = {
  __proto__: p,
  get g() {
    return super.x;
  },
};
console.log(o.g);
