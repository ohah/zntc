function* g() {
  try { yield 1; yield 2; yield 3; }
  finally { /* @ts-ignore */ console.log("cleanup"); }
}
const it = g();
console.log(it.next().value, it.return(99).value, it.next().done);
