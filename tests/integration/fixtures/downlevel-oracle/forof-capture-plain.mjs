const fLong = [];
for (const xLong of [1, 2]) fLong.push(() => xLong);
for (let [aLong, bLong] of [[3, 4]]) fLong.push(() => aLong + bLong);
console.log(fLong.map((hLong) => hLong()).join());
