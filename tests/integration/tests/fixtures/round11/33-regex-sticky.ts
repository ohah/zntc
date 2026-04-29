const re = /\d+/y;
const s = "1 2 3";
re.lastIndex = 0;
console.log(re.exec(s)?.[0], re.lastIndex);
re.lastIndex = 2;
console.log(re.exec(s)?.[0], re.lastIndex);
