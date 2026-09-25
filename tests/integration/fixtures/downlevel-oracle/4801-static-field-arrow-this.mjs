// static 필드 초기값 화살표의 this·super — 클래스 밖으로 옮겨도 클래스를 가리켜야 한다 (#4801)
const out = [];
class A {
  static x = 1;
  static f = () => this.x;
}
out.push(A.f());
function make(base) {
  return class B extends base {
    static y = 2;
    static g = () => this.y + (this === B);
  };
}
out.push(make(Object).g());
const C = class {
  static z = 3;
  static h = () => this.z;
};
out.push(C.h());
const D = class Named {
  static w = 4;
  static k = () => this.w + Named.w;
};
out.push(D.k());
function mk2() {
  return class {
    static v = 5;
    static m = (p) => [this.v, p].join(':');
  };
}
out.push(mk2().m('p'));
function mk3() {
  class Inner {
    static q = 6;
    static n = () => this.q;
  }
  return Inner;
}
out.push(mk3().n());
console.log(out.join(','));
