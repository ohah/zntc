const fLong = [];
for (let iLong = 0; iLong < 2; iLong++) {
  var wLong = iLong;
  fLong.push(() => iLong);
}
console.log(fLong.map((gLong) => gLong()).join(), wLong);
