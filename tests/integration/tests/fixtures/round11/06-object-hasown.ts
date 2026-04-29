const obj = Object.create({ inherited: 1 });
obj.own = 2;
console.log(Object.hasOwn(obj, "own"), Object.hasOwn(obj, "inherited"), "own" in obj, "inherited" in obj);
