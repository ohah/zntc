const log: string[] = [];
class A { static { log.push("A1"); } static x = (log.push("Ax"), 1); static { log.push("A2"); } }
console.log(log.join(","), A.x);
