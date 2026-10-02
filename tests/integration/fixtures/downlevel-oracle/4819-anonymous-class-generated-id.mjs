// Anonymous class lowering generates an inner constructor name. Two sibling
// class IIFEs intentionally reuse that generated spelling, while source names
// occupy the first candidates. Their semantic IDs must remain scope-specific.
const _Class = 'outer';
class Base {}

function create(_Class2) {
  const First = class extends Base {
    static value = this.readValue();
    static readValue() {
      return 10;
    }
  };
  const Second = class extends Base {
    static value = this.readValue() + 1;
    static readValue() {
      return 20;
    }
  };
  return [First.value, Second.value, First.readValue() === 10, Second.readValue() === 20, _Class2];
}

console.log([_Class, ...create('parameter')].join(','));
