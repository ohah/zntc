// 사용자 _super·_this 와 클래스 낮추기의 합성 이름, 헬퍼와 같은 이름의 사용자 변수
const out = [];
class Base {
  static s() {
    return 'base';
  }
  get g() {
    return 'bg';
  }
}
class D extends Base {
  constructor() {
    const _super = 'user-super',
      _this = 'user-this2';
    super();
    out.push(_super, _this, super.g);
  }
  static t() {
    const _super = 'u-s';
    return super.s() + _super;
  }
}
new D();
out.push(D.t());
const _default = 'user-default',
  _jsx = 'user-jsx',
  _classPrivateFieldGet = 'user-helper';
class P {
  #x = 1;
  get x() {
    return this.#x;
  }
}
out.push(new P().x, _default, _jsx, _classPrivateFieldGet);
console.log(out.join(' / '));
