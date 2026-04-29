class A { greet(){ return "A"; } }
class B extends A {
  greet(){
    const f = () => super.greet() + "/B";
    return f();
  }
}
console.log(new B().greet());
