// 사용자 변수 이름이 변환의 합성 이름(_this·_arguments·_loop·_ret·_state·_step)과 같아도 서로 가리지 않는다
const out = [];
function outer() {
  const _this = 'user-this',
    _arguments = 'user-args',
    _loop = 'user-loop',
    _ret = 'user-ret';
  const f = () => [this && this.tag, _this, arguments[0], _arguments].join('|');
  const fns = [];
  for (let i = 0; i < 2; i++) {
    fns.push(() => i + _loop);
    if (i > 5) return _ret;
  }
  return f() + '#' + fns.map((g) => g()).join(',');
}
out.push(outer.call({ tag: 'T' }, 'A0'));
function* gen() {
  const _state = 'user-state',
    _step = 'user-step',
    _iterator = 'it';
  for (const x of [1]) {
    yield x + _state + _step + _iterator;
  }
}
out.push([...gen()].join());
async function am() {
  const _this = 'u2';
  await null;
  return (() => _this)();
}
class K {
  m() {
    const _this = 'u3';
    return [() => this.v, () => _this].map((g) => g()).join();
  }
}
K.prototype.v = 'kv';
am().then((v) => {
  out.push(v, new K().m());
  console.log(out.join(' / '));
});
