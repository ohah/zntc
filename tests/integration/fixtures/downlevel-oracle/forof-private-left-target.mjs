class C {
  #x = 0;
  run() {
    const seen = [];
    for (this.#x of [1, 2]) seen.push(this.#x);
    return seen.join() + ':' + this.#x;
  }
}
console.log(new C().run());
