class C {
  *m(xs) {
    for (const x of xs) yield this.k + x;
  }
}
C.prototype.k = 'k';
console.log([...new C().m([1, 2])].join());
