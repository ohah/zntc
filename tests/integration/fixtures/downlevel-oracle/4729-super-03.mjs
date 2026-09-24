const p = {};
const o = {
  __proto__: p,
  s(v) {
    super.y = v;
    return this.y;
  },
};
console.log(o.s(3), Object.hasOwn(o, 'y'), p.y);
