function f() {
  return
    1
}
console.log(f());

const a = 1
const b = 2
;[a, b].forEach(x => console.log(x))

const c = [1,2,3]
const d = c
  .map(x => x * 2)
  .reduce((s, x) => s + x, 0)
console.log(d);
