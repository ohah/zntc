function effect() { console.log("called"); return 1; }
const dead = /* @__PURE__ */ effect();
console.log("done");
