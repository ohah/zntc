const { a: { b: [c, , { d = 99 } = {} as any] } } = { a: { b: [1, 2, { d: undefined }] } } as any;
console.log(c, d);
