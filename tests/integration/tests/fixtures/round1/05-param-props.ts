class P {
  constructor(public x: number, private y: string, readonly z: boolean) {}
  show() { return `${this.x}/${this.y}/${this.z}`; }
}
console.log(new P(1, "a", true).show());
