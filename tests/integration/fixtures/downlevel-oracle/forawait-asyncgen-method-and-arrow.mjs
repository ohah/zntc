const oLong = {
  async *m(sLong) {
    for await (const vLong of sLong) yield vLong + 1;
  },
};
class CLong {
  async *n(sLong2) {
    for await (const vLong2 of sLong2) yield vLong2 * 3;
  }
}
const fLong = async (sLong3) => {
  const rLong = [];
  for await (const vLong3 of sLong3) rLong.push(vLong3);
  return rLong;
};
(async () => {
  const out = [];
  for await (const vLong4 of oLong.m([1, 2])) out.push(vLong4);
  for await (const vLong5 of new CLong().n([1])) out.push(vLong5);
  out.push((await fLong([7, 8])).join(''));
  console.log(out.join());
})();
