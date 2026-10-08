/** @jsxRuntime classic */
/** @jsx h */
/** @jsxFrag Fragment */
function render(h, Fragment) {
  function nested(h, Fragment) {
    return (
      <>
        <span />
      </>
    );
  }
  return <div>{nested(h, Fragment)}</div>;
}

console.log(JSON.stringify(render((tag, _props, ...children) => ({ tag, children }), 'Fragment')));
