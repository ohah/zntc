import { LRUCache } from "lru-cache";
const c = new LRUCache({ max: 10 });
c.set("a", 1);
console.log(c.get("a"));
