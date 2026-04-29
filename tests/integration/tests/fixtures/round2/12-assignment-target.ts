let arr = [1, 2, 3]; let obj: any = { a: 1 };
[arr[0], arr[1]] = [arr[1], arr[0]];
({ a: obj.b, c: obj.d = 99 } = { a: 10, c: undefined });
console.log(arr.join(","), JSON.stringify(obj));
