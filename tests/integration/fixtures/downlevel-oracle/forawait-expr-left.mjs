const o = {};
(async () => {
  const seen = [];
  for await (o.p of [1, 2]) seen.push(o.p);
  console.log(seen.join(), o.p);
})();
