// static 초기값·static 블록 안 메서드·getter·중첩 클래스의 this 는 치환하면 안 된다 (#4801)
const out = [];
const keyHolder = { k: 'dyn' };
function outer() {
  return class A {
    static self = this;
    static fnThis = function () {
      return this === A.receiver;
    };
    static receiver = {};
    static nested = () =>
      class {
        m() {
          return this instanceof A.nestedCls;
        }
      };
    static nestedCls = A.nested();
    static arrowNested = () => () => this.name;
    static [this === keyHolder ? 'dyn' : 'plain'] = 1;
    static obj = {
      get g() {
        return this === A.obj;
      },
      arrow: () => this,
    };
  };
}
const A = outer.call(keyHolder);
out.push(
  A.self === A,
  A.fnThis.call(A.receiver),
  new A.nestedCls().m(),
  A.arrowNested()(),
  'dyn' in A,
  A.obj.g,
  A.obj.arrow() === A,
);
console.log(out.join(','));
