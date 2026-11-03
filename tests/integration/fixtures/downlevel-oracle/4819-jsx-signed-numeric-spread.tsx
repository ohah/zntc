/** @jsx React.createElement */
const React = {
  createElement(type, props) {
    const children = Array.prototype.slice.call(arguments, 2);
    return { type, props, children };
  },
};

const member = {
  '0': 'zero',
  '1': 'one',
  '-2': 'minus-two',
  '16': 'hex',
  '-100': 'exponent',
  true: 'truthy',
  undefined: 'undefined',
  number: 'numeric',
  string: 'string',
};
const items = [1, 2];
const result = (
  <div
    {...{
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
      valueLogicalNotZero: !0,
      valueLogicalNotBigInt: !0n,
      valueLogicalNotFalse: !false,
      valueLogicalNotTemplate: !`static`,
      valueBitwiseNotZero: ~0,
      valueBitwiseNotBigInt: ~1n,
      valueBitwiseNotString: ~`2`,
      keyLogicalNot: member[!false],
      keyBitwiseNot: member[~1],
      keyBitwiseNotBigInt: member[~1n],
      voidLogicalNot: void !0,
      voidBitwiseNotBigInt: void ~1n,
      voidSignedNegativeZero: void -0,
      voidLogicalNotKey: member[void !false],
      voidBitwiseNotKey: member[void ~1],
      voidSignedPositiveKey: member[void +2],
      typeofNumber: typeof 0,
      typeofBigInt: typeof 0n,
      typeofBoolean: typeof true,
      typeofNull: typeof null,
      typeofString: typeof 'x',
      typeofTemplate: typeof `static`,
      keyTypeofNumber: member[typeof 0],
      keyTypeofString: member[typeof `x`],
    }}
    key='k'
  >
    {...items}
  </div>
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
  result.props.valueLogicalNotZero,
  result.props.valueLogicalNotBigInt,
  result.props.valueLogicalNotFalse,
  result.props.valueLogicalNotTemplate,
  result.props.valueBitwiseNotZero,
  result.props.valueBitwiseNotBigInt,
  result.props.valueBitwiseNotString,
  result.props.keyLogicalNot,
  result.props.keyBitwiseNot,
  result.props.keyBitwiseNotBigInt,
  result.props.voidLogicalNot,
  result.props.voidBitwiseNotBigInt,
  result.props.voidSignedNegativeZero,
  result.props.voidLogicalNotKey,
  result.props.voidBitwiseNotKey,
  result.props.voidSignedPositiveKey,
  result.props.typeofNumber,
  result.props.typeofBigInt,
  result.props.typeofBoolean,
  result.props.typeofNull,
  result.props.typeofString,
  result.props.typeofTemplate,
  result.props.keyTypeofNumber,
  result.props.keyTypeofString,
  JSON.stringify(result.children),
);
