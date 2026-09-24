const oLong = {};
function* gLong() {
  for (oLong.p in { u: 1, v: 2 }) yield oLong.p;
}
console.log([...gLong()].join(), oLong.p);
