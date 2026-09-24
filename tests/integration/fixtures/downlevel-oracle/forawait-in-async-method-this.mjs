class CLong {
  constructor() {
    this.k = 'K';
  }
  async run(sLong) {
    const out = [];
    for await (const vLong of sLong) out.push(this.k + vLong);
    return out.join();
  }
}
new CLong().run([1, 2]).then(console.log);
