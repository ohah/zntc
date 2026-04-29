function compute(
  x: number,
  y: number,
  z: number,
): number {
  const sum = x + y + z;
  const product = x * y * z;
  return sum + product;
}
console.log(compute(1, 2, 3));
