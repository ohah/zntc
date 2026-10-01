async function run(value) {
  return await value;
}

run(Promise.resolve(7)).then((value) => console.log(JSON.stringify([value])));
