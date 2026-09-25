// 배열 rest 안에 중첩된 객체 rest — es2017 에서도 낮춰야 한다 (#4789)
let headLong, keyLong, remainLong;
[headLong, ...{ keyLong, ...remainLong }] = [1, 2, 3];
console.log(headLong, keyLong, JSON.stringify(remainLong));
