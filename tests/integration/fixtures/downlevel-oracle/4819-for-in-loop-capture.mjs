var source = Object.create({ inherited: 3 });
source.first = 1;
source.second = 2;
var readers = [];
outerLoop: for (const key in source) {
  if (key === 'first' || key === 'second') {
    readers.push(() => key);
    continue outerLoop;
  }
  readers.push(() => key);
}
console.log(readers.map((read) => read()).join(','));
