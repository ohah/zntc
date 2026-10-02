// Array elements remain anonymous, so the ES5 lowerer creates inner names.
// Their static-block `this` reads must use distinct scope-owned SymbolIds.
const _Class = 'outer';
class Base {}
globalThis.__zntcAnonymousClassSelfs = [];

function create(_Class2) {
  const pair = [
    class extends Base {
      static {
        globalThis.__zntcAnonymousClassSelfs.push(this);
      }
      static readValue() {
        return 10;
      }
    },
    class extends Base {
      static {
        globalThis.__zntcAnonymousClassSelfs.push(this);
      }
      static readValue() {
        return 20;
      }
    },
  ];
  const First = pair[0];
  const Second = pair[1];
  return [First.readValue(), Second.readValue(), _Class2];
}

console.log([_Class, ...create('parameter')].join(','));
