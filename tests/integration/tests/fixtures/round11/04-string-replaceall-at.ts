const s = "abc-abc-abc";
const replaced = s.replaceAll("abc", "X");
const at1 = s.at(-1);
const at2 = s.at(0);
console.log(replaced, at1, at2);
