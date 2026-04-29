class Multiple {
  static [Symbol.hasInstance](v: any) {
    return typeof v === "number" && v % 3 === 0;
  }
}
console.log(6 instanceof Multiple, 7 instanceof Multiple, 9 instanceof (Multiple as any));
