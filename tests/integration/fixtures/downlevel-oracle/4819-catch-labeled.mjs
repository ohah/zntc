function runContinue() {
  const captured = [];
  outer: for (let index = 0; index < 3; index++) {
    try { throw 0; } catch (caught) {
      if (index === 1) continue outer;
      captured.push(() => index);
    }
  }
  return captured.map(callback => callback());
}

function runBreak() {
  const captured = [];
  outer: for (let index = 0; index < 3; index++) {
    try { throw 0; } catch (caught) {
      captured.push(() => index);
      if (index === 1) break outer;
    }
  }
  return captured.map(callback => callback());
}

console.log(JSON.stringify([runContinue(), runBreak()]));
