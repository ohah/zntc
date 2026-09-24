label: {
  const o = {
    __proto__: {
      m() {
        return 'p';
      },
    },
    n() {
      return super.m();
    },
  };
  console.log(o.n());
  break label;
}
