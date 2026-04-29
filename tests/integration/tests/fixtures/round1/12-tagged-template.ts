function tag(s: TemplateStringsArray, ...v: any[]) {
  return [s.join("|"), s.raw.join("|"), v.join(",")].join("##");
}
console.log(tag`a\nb${1}c\td${2}e`);
