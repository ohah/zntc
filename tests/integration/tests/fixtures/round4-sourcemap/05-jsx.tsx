const React = { createElement: (t: any, p: any, ...c: any[]) => ({ t, p, c }), Fragment: "F" };
function App() {
  return (
    <div>
      <h1>Hello</h1>
      <p>World</p>
    </div>
  );
}
console.log(JSON.stringify(App()));
