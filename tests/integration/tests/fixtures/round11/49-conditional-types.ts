type IsString<T> = T extends string ? "yes" : "no";
type A = IsString<"hello">;
type B = IsString<number>;
const a: A = "yes";
const b: B = "no";
function pick<T>(x: T): T { return x; }
console.log(pick(a), pick(b), pick<string>("ok"));
