// 여러 변환의 합성 이름(_newTarget·_using·_stack·_Class·_metadata·_keys…)을 사용자가 모두 선언
const out = [];
const _newTarget = 'nt',
  _state = 'st',
  _ret = 'rt',
  _step = 'sp',
  _iterator = 'it',
  _using = 'us',
  _stack = 'sk',
  _error = 'er',
  _hasError = 'he',
  _Class = 'cl',
  _classThis = 'ct',
  _metadata = 'md',
  _keys = 'ks',
  _idx = 'ix',
  _jsx = 'jx',
  _loop = 'lp',
  _this = 'th',
  _super = 'su',
  _arguments = 'ar';
const userVals = () =>
  [
    _newTarget,
    _state,
    _ret,
    _step,
    _iterator,
    _using,
    _stack,
    _error,
    _hasError,
    _Class,
    _classThis,
    _metadata,
    _keys,
    _idx,
    _jsx,
    _loop,
    _this,
    _super,
    _arguments,
  ].join('');
function Ctor() {
  out.push(new.target === Ctor ? 'nt-ok' : 'nt-bad');
}
new Ctor();
function* gen(o) {
  for (const k in o) {
    yield k;
  }
  for (const v of [1, 2]) {
    const fns = [];
    for (let i = 0; i < 1; i++) {
      fns.push(() => i + v);
      if (v > 9) return 'x';
    }
    yield fns[0]();
  }
}
out.push([...gen({ a: 1 })].join(''));
async function withUsing() {
  const R = {
    [Symbol.dispose]() {
      out.push('disp');
    },
  };
  {
    using r = R;
    out.push('in');
  }
  await null;
  return 'u';
}
class B {
  static s() {
    return 'bs';
  }
  m() {
    return 'bm';
  }
}
const Anon = class extends B {
  static t = () => super.s() + typeof this;
  m() {
    const f = () => super.m() + arguments.length;
    return f();
  }
};
out.push(Anon.t(), new Anon().m());
const arr = [...'ab', ...[3]];
out.push(arr.join(''));
const { a, ...restObj } = { a: 1, b: 2 };
out.push(Object.keys(restObj).join(''));
withUsing().then((v) => {
  out.push(v, userVals());
  console.log(out.join(','));
});
