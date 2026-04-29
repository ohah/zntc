const r = /(?<year>\d{4})-(?<month>\d{2})/d;
const m = "2026-04".match(r);
console.log(m?.groups?.year, m?.groups?.month, (m as any)?.indices?.groups?.year?.[0]);
