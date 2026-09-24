function* gLong() {
  for (const [cLong, dLong = '-'] in { ab: 1, c: 2 }) yield cLong + dLong;
}
console.log([...gLong()].join());
