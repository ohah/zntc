// static 필드 안 super 와 익명 클래스 식 (#4801)
const C = class {
  static z = 3;
  static h = () => this.z;
};
function mk() {
  return class B extends Object {
    static y = 2;
    static g = () => this.y;
  };
}
class P {
  static s() {
    return 'ps';
  }
}
class Q extends P {
  static t = () => super.s() + this.name;
}
console.log(C.h(), mk().g(), Q.t());
