/** @jsxRuntime classic */
/** @jsx React.createElement */
/** @jsxFrag React.Fragment */
function render(React) {
  function nested(React) {
    return <><span /></>;
  }
  return <div>{nested(React)}</div>;
}

const ReactFactory = {
  createElement: (tag, _props, ...children) => ({ tag, children }),
  Fragment: 'Fragment',
};
console.log(JSON.stringify(render(ReactFactory)));
