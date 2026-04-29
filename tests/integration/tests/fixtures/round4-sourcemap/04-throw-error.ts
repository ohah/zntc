function level3() {
  throw new Error("boom");
}
function level2() {
  level3();
}
function level1() {
  level2();
}
try {
  level1();
} catch (e: any) {
  console.log(e.stack?.split("\n").slice(0, 5).join("\n"));
}
