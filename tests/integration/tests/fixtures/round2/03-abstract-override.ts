abstract class Base { abstract greet(): string; common() { return "common:" + this.greet(); } }
class Impl extends Base { override greet() { return "impl"; } }
console.log(new Impl().common());
