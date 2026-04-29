let log: string[] = [];
class G {
  _x = 0;
  get x(){ log.push("get"); return this._x; }
  set x(v: number){ log.push("set:" + v); this._x = v; }
}
const g = new G();
g.x = 5; g.x += 2;
console.log(g.x, log.join(","));
