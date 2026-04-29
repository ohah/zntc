const React = {
  createElement(type: any, props: any, ...children: any[]) {
    return { type, props: props || {}, children };
  },
  Fragment: "Fragment"
};
const el = (
  <>
    <div className="a" {...{ id: "x" }}>hello {1 + 2}</div>
    <span />
  </>
);
console.log(JSON.stringify(el));
