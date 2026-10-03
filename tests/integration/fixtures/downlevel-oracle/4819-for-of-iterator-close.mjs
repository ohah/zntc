const events = [];
const iterable = {
  [Symbol.iterator]() {
    let current = 0;
    return {
      next() {
        current += 1;
        return { value: current, done: current > 3 };
      },
      return() {
        events.push(`return:${current}`);
        return { done: true };
      },
    };
  },
};

const values = [];
outerLoop: for (const loopValue of iterable) {
  values.push(loopValue);
  if (loopValue === 1) continue outerLoop;
  if (loopValue === 2) break outerLoop;
}

const capturedValues = [];
for (let lexicalValue of [3, 4, 5]) {
  capturedValues.push(() => lexicalValue);
}
console.log(values.join(','), events.join(','), capturedValues.map((read) => read()).join(','));
