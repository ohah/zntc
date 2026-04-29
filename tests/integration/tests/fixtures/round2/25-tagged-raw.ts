const tag = (s: TemplateStringsArray, ..._v: any[]) => [s.join("|"), s.raw.join("|")].join("##");
console.log(tag`a\nbéc\td`);
