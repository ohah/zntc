const arr = [3, 1, 4, 1, 5, 9, 2, 6];
const sorted = arr.toSorted();
const reversed = arr.toReversed();
const spliced = arr.toSpliced(1, 2, 99);
const replaced = arr.with(0, 0);
console.log(arr.length, sorted, reversed, spliced, replaced);
