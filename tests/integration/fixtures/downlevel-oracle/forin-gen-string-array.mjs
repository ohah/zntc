function* gLong() {
  for (const iLong in 'ab') yield iLong;
  for (const iLong2 in [5, 6]) yield iLong2;
}
console.log([...gLong()].join());
