const oLong = {};
(async () => {
  const seen = [];
  for await (oLong.p of [1, 2]) seen.push(oLong.p);
  console.log(seen.join(), oLong.p);
})();
