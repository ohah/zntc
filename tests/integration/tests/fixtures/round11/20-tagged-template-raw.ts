function tag(strings: TemplateStringsArray, ...values: any[]) {
  return { cooked: [...strings], raw: [...strings.raw], values };
}
const x = 42;
const result = tag`a\n${x}\tb`;
console.log(JSON.stringify(result));
