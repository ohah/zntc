// 대입 rest 자리의 private 필드·super 멤버 — 구조 분해를 지원하는 타깃에서도 낮춰야 한다 (#4789)
const out = [];
class Box {
  #itemsLong;
  static baseLong = [];
  fill(src) {
    [this.firstLong, ...this.#itemsLong] = src;
    return this.#itemsLong.join('/');
  }
}
out.push(new Box().fill([1, 2, 3]));
class Base {
  set restLong(v) {
    out.push('set:' + v.join('/'));
  }
}
class Child extends Base {
  run() {
    [this.headLong, ...super.restLong] = [5, 6, 7];
  }
}
new Child().run();
function* g() {
  let aLong, bLong;
  [aLong, ...bLong] = yield 0;
  out.push(aLong, bLong.join('/'));
}
const it = g();
it.next();
it.next(new Set([1, 2, 3]));
async function h() {
  let aLong, bLong;
  [aLong, ...bLong] = await Promise.resolve([4, 5]);
  out.push(aLong, bLong.join('/'));
}
h().then(() => console.log(out.join(',')));
