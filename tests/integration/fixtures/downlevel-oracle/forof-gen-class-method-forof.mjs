class CLong {
  *m(xs) {
    for (const xLong of xs) yield this.k + xLong;
  }
}
CLong.prototype.k = 'k';
console.log([...new CLong().m([1, 2])].join());
