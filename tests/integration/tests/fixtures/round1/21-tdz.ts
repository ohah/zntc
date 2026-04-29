try {
  // @ts-ignore
  console.log(x);
  let x = 1;
} catch (e: any) {
  console.log("TDZ:", e.constructor.name);
}
const make = () => {
  let count = 0;
  return () => ++count;
};
const c = make();
console.log(c(), c(), c());
