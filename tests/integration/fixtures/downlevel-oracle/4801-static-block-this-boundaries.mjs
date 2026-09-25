// static 블록 안 객체 getter·중첩 클래스 메서드의 this (#4801)
class A {
  static r = {};
  static {
    A.obj = {
      get g() {
        return this === A.obj;
      },
    };
    A.C = class {
      m() {
        return this instanceof A.C;
      }
    };
  }
}
console.log(A.obj.g, new A.C().m());
