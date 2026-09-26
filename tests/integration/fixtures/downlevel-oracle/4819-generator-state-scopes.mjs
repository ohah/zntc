function* outer() {
  yield 1;
  const inner = function* () { yield 2; };
  yield inner().next().value;
}

async function load(value) {
  try {
    return await Promise.resolve(value + 1);
  } catch (error) {
    return error.message;
  }
}

const arrow = async (value) => await Promise.resolve(value + 2);

class Box {
  async load(value) {
    const nested = async () => await Promise.resolve(value + 3);
    return await nested();
  }
}

const object = {
  async load(value) {
    const nested = async () => await Promise.resolve(value + 4);
    return await nested();
  },
};

(async () => {
  const values = [
    [...outer()].join(','),
    await load(10),
    await arrow(10),
    await new Box().load(10),
    await object.load(10),
  ];
  console.log(values.join('|'));
})();
