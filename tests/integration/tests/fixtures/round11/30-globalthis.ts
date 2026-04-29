(globalThis as any).MY_VAR = 42;
console.log((globalThis as any).MY_VAR, typeof globalThis);
delete (globalThis as any).MY_VAR;
console.log((globalThis as any).MY_VAR);
