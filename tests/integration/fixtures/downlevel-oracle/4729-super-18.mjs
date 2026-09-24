const oLong = {
  toString() {
    return 'X' + super.toString();
  },
};
console.log(String(oLong));
