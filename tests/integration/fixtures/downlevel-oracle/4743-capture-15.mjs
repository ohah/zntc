const f = [];
async function g() {
  let i = 0;
  while (i < 2) {
    const v = i++;
    await 0;
    f.push(() => v);
  }
}
g().then(() => console.log(f.map((h) => h()).join()));
