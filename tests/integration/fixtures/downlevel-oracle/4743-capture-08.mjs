function t() {
  const f = [];
  for (var i = 0; i < 3; i++) {
    const v = i;
    f.push(() => v);
    if (i === 1) return f;
  }
}
console.log(
  t()
    .map((g) => g())
    .join(),
);
