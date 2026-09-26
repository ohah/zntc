function run() {
  const captured = [];
  for (let index = 0; index < 3; index++) {
    try {
      throw 0;
    } catch (caught) {
      if (index === 1) continue;
      captured.push(() => index);
    }
  }
  return captured.map((callback) => callback());
}
console.log(JSON.stringify(run()));
