const re = /(?<=\$)\d+/g;
const matches = "$10 €20 $30".match(re);
const negRe = /(?<!\$)\d+/g;
const negMatches = "$10 €20 $30".match(negRe);
console.log(matches, negMatches);
