// async 상태 기계 — await 결과가 이터러블인 배열 구조 분해 (#4791)
const out = [];
async function run() {
  const [aLong, ...restLong] = await Promise.resolve(new Set([1, 2, 3]));
  out.push(aLong, restLong.join('/'));
  const {
    mapLong: [[kLong, vLong]],
  } = await { mapLong: new Map([['key', 'val']]) };
  out.push(kLong, vLong);
  for (const [iLong, , jLong] of [[1, 2, 3], new Set([4, 5, 6])]) {
    await null;
    out.push(iLong + jLong);
  }
}
run().then(() => console.log(out.join(',')));
