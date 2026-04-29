const x = `${`${`${1}`}${2}`}${3}`;
const tag = (s: TemplateStringsArray, ...v: any[]) => s.raw.join("|") + "##" + v.join(",");
const y = tag`a${1}b${`${2}`}c`;
console.log(x, y);
