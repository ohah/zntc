// static private 필드 초기값의 this — 클래스 밖 descriptor 로 옮겨도 클래스를 가리킨다 (#4801 후속)
class A {
  static y = 1;
  static #x = () => this.y;
  static #self = () => this;
  static get() {
    return [A.#x(), A.#self() === A].join();
  }
}
console.log(A.get());
