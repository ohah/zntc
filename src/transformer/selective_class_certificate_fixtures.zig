// Valid source programs shared by birth and hostile identity checks.
pub const sources = [_][]const u8{
    "function P(){}class D extends P{constructor(){var go=()=>super();go()}}console.log(new D() instanceof P)",
    "function P(){}class D extends P{constructor(){var go=()=>{return super()};go()}}console.log(new D() instanceof P)",
    "function P(){}class D extends P{constructor(){var go=()=>super();if(true)go()}}console.log(new D() instanceof P)",
    "function P(){}class D extends P{constructor(){var go=()=>()=>super();go()()}}console.log(new D() instanceof P)",
    "function P(){}class D extends P{constructor(){var go=()=>super(42);return go()}}console.log(new D() instanceof P)",
    "function P(){}class D extends P{constructor(){var x=42;var go=()=>super(x);go()}}console.log(new D() instanceof P)",
    "var saved;function P(){}class D extends P{constructor(){saved=()=>super();saved()}}console.log(new D() instanceof P)",
    "function P(){}class D extends P{constructor(){var go=()=>super();go();try{go()}catch(e){console.log(e instanceof ReferenceError)}}}new D()",
    "var __callSuper=42;function P(){}class D extends P{constructor(){var go=()=>super();go()}}console.log(new D() instanceof P,__callSuper)",
    "function Empty(){}function P(){}class D extends P{constructor(){var go=()=>super();go()}}console.log(new D() instanceof P,new Empty() instanceof Empty)",
};
