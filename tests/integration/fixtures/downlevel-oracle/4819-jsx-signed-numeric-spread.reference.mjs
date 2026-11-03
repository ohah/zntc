const React = {
  createElement(type, props, ...children) {
    return { type, props, children };
  },
};

const member = {
  0: 'zero',
  1: 'one',
  '-2': 'minus-two',
  16: 'hex',
  '-100': 'exponent',
};
const items = [1, 2];
const result = React.createElement(
  'div',
  {
    valueNegativeZero: -0,
    valuePositiveOne: +1,
    valueNegativeParen: -2,
    valuePositiveHex: +0x10,
    valueNegativeExponent: -1e2,
    keyNegativeZero: member[-0],
    keyPositiveOne: member[+1],
    keyNegativeParen: member[-2],
    keyPositiveHex: member[+0x10],
    keyNegativeExponent: member[-1e2],
    key: 'k',
  },
  ...items,
);

console.log(
  result.type,
  result.props.key,
  Object.is(result.props.valueNegativeZero, -0),
  result.props.valuePositiveOne,
  result.props.valueNegativeParen,
  result.props.valuePositiveHex,
  result.props.valueNegativeExponent,
  result.props.keyNegativeZero,
  result.props.keyPositiveOne,
  result.props.keyNegativeParen,
  result.props.keyPositiveHex,
  result.props.keyNegativeExponent,
  JSON.stringify(result.children),
);
