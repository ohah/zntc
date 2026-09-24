const o = {
  toString() {
    return 'X' + super.toString();
  },
};
console.log(String(o));
