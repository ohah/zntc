import { load } from "cheerio"; const doc = load("<h1>Hello</h1>"); console.log(doc("h1").text());
