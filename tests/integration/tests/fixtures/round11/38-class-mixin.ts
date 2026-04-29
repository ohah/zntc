type Ctor<T = {}> = new (...args: any[]) => T;
function Loggable<TBase extends Ctor>(Base: TBase) {
  return class extends Base {
    log(msg: string) { return `[log] ${msg}`; }
  };
}
class Animal { name = "Rex"; }
class LoggableAnimal extends Loggable(Animal) {}
const a = new LoggableAnimal();
console.log(a.name, a.log("hi"));
