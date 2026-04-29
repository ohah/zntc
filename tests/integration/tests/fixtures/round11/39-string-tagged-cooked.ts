function html(strings: TemplateStringsArray, ...values: any[]) {
  return strings.reduce((acc, s, i) => acc + s + (values[i] ?? ""), "");
}
const name = "<world>";
const result = html`<b>${name}</b>`;
console.log(result);
