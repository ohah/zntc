class C {
  constructor() {
    this.k = 'K';
  }
  async run(s) {
    const out = [];
    for await (const v of s) out.push(this.k + v);
    return out.join();
  }
}
new C().run([1, 2]).then(console.log);
