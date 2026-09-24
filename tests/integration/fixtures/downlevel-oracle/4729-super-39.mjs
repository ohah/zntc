label: {
  const oLong = {
    __proto__: {
      m() {
        return 'p';
      },
    },
    n() {
      return super.m();
    },
  };
  console.log(oLong.n());
  break label;
}
