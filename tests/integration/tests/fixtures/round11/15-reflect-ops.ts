const obj: any = { a: 1 };
Reflect.set(obj, "b", 2);
const got = Reflect.get(obj, "a");
const has = Reflect.has(obj, "b");
const del = Reflect.deleteProperty(obj, "a");
const keys = Reflect.ownKeys(obj);
console.log(got, has, del, keys, JSON.stringify(obj));
