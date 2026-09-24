for (var vLong of [1, 2, 3]);
function* gLong() {
  for (var wLong of [4, 5]) yield wLong;
}
console.log(vLong, [...gLong()].join());
