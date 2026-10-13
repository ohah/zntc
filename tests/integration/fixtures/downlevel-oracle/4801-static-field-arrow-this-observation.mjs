class Box {
  static count = 7;
  static read = () => this.count;
}

const read = Box.read;
console.log(read());
