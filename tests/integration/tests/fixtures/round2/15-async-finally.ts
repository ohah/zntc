async function f() {
  try { return 1; } finally { /* return 2 in finally would override */ }
}
async function g() {
  try { return 1; } finally { return 2; }
}
Promise.all([f(), g()]).then(([a, b]) => console.log(a, b));
