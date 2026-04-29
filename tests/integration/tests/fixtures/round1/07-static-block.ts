class S {
  static a = 1;
  static b: number;
  static { this.b = this.a + 10; }
}
console.log(S.a, S.b);
