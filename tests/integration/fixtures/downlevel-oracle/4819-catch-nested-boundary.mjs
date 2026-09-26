function run() {
  const values = [];
  outer: for (let index = 0; index < 3; index++) {
    try {
      throw 0;
    } catch {
      const captured = () => index;
      function local() {
        return `local${captured()}`;
      }
      for (let inner = 0; inner < 3; inner++) {
        if (inner === 1) break;
        values.push(local());
      }
      if (index === 1) continue outer;
      values.push(`tail${captured()}`);
    }
  }
  return values;
}
console.log(JSON.stringify(run()));
