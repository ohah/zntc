// --- index.ts ---
var load = require("cheerio").load;

const doc = load("<h1>Hello</h1>");
console.log(doc("h1").text());

