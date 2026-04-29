function fn(cond: boolean) {
  if (cond) {
    let x = 1;
    return x;
  }
  return -1;
}
console.log(fn(true), fn(false));

let y = 10;
{
  let y = 20;
  console.log(y);
}
console.log(y);
