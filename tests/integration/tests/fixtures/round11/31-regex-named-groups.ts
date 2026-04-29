const re = /(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})/;
const m = "2026-04-29".match(re);
console.log(m?.groups?.year, m?.groups?.month, m?.groups?.day);
const replaced = "2026-04-29".replace(re, "$<day>/$<month>/$<year>");
console.log(replaced);
