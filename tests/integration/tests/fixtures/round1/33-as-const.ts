const xs = [1, 2, 3] as const;
const t = { name: "x", value: 5 } as const;
console.log(xs.join(","), t.name, t.value);
