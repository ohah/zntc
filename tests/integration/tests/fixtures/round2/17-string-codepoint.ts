const s = "a\u{1F600}b\u{D83D}\u{DE00}c";
console.log(s.length, [...s].length, s.codePointAt(1)?.toString(16));
