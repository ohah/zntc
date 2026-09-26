function run() {
  const captured = [];
  for (let index = 0; index < 3; index++) {
    try {
      throw 0;
    } catch (caught) {
      captured.push(() => index);
      if (index === 1) break;
    }
  }
  return captured.map((callback) => callback());
}
console.log(JSON.stringify(run()));
