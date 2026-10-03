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
for (const loopValue of iterable) {
  values.push(loopValue);
  if (loopValue === 2) break;
}
console.log(values.join(','), events.join(','));
