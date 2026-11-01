function read(input) {
  var match = /(?<word>[a-z]+)-\d+/.exec(input);
  return match && match.groups.word;
}

console.log(read('abc-42'));
