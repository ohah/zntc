class Calculator {
  result: number = 0;
  add(n: number): this {
    this.result += n;
    return this;
  }
  multiply(n: number): this {
    this.result *= n;
    return this;
  }
}
const calc = new Calculator();
calc.add(5).multiply(3);
console.log(calc.result);
