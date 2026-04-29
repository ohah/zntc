const s1 = "a\tb\nc\\d\"eéf\u{1f600}g";
const s2 = `tpl ${"x"} \\${"y"} \r raw`;
console.log(s1.length, s2.length, JSON.stringify(s1), JSON.stringify(s2));
