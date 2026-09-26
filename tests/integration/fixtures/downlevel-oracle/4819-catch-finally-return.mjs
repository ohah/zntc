const trace = [];
function run() {
  for (let index = 0; index < 3; index++) {
    try { throw 0; } catch (caught) {
      const captured = () => index;
      if (index === 1) return captured();
    } finally {
      trace.push(index);
    }
  }
  return -1;
}
console.log(JSON.stringify([run(), trace]));
