import { describe, test, expect } from "bun:test";
import { createFixture, runZts } from "./helpers";

/**
 * Flow + JSX 회귀 테스트 — React Native 소스에서 추출한 패턴.
 * --flow --jsx-in-js 로 트랜스파일 성공을 확인한다.
 * 실제 RN Libraries 파일에서 발견된 구문을 최소 재현으로 테스트.
 */

async function expectFlowPass(code: string) {
  const fixture = await createFixture({ "input.js": code });
  try {
    const result = await runZts(["--flow", "--jsx-in-js", `${fixture.dir}/input.js`]);
    expect(result.exitCode).toBe(0);
    expect(result.stderr).not.toContain("error:");
  } finally {
    await fixture.cleanup();
  }
}

describe("Flow + JSX: React Native patterns", () => {
  // === ImageBackground.js 패턴 ===
  test("class component with typed methods and JSX", async () => {
    await expectFlowPass(`
// @flow strict-local
import * as React from 'react';

class ImageBackground extends React.Component<{style: any, children: any}> {
  setNativeProps(props: {...}) {}
  _viewRef: ?Object = null;
  _captureRef = (ref: null | Object) => { this._viewRef = ref; };
  render(): React.Node {
    const { children, style, ...props } = this.props;
    return (
      <View style={style} ref={this._captureRef}>
        <Image {...props} />
        {children}
      </View>
    );
  }
}
export default ImageBackground;
`);
  });

  // === View.js 패턴: component declaration ===
  test("Flow component declaration with JSX", async () => {
    await expectFlowPass(`
// @flow strict-local
import * as React from 'react';

component View(ref?: any, ...props: any) {
  const actualView = ref == null ? (
    <ViewNative {...props} />
  ) : (
    <ViewNative {...props} ref={ref} />
  );
  return actualView;
}
export default View;
`);
  });

  // === Text.js 패턴: component type annotation + const ===
  test("component type annotation", async () => {
    await expectFlowPass(`
// @flow strict-local
const TextImpl: component(
  ref?: any,
  ...props: any
) = ({ref, ...props}) => null;
export default TextImpl;
`);
  });

  // === TouchableOpacity.js 패턴: component + class 조합 ===
  test("component wrapper around class", async () => {
    await expectFlowPass(`
// @flow strict-local
class TouchableOpacityImpl {
  render() { return null; }
}

const Touchable: component(
  ref?: any,
  ...props: any
) = ({ref, ...props}) => null;

export default Touchable;
`);
  });

  // === FlatList.js 패턴: generic class + typed arrow fields ===
  test("generic class with typed arrow field", async () => {
    await expectFlowPass(`
// @flow strict-local
import * as React from 'react';

class FlatList<ItemT = any> extends React.PureComponent<{data: Array<ItemT>}> {
  scrollToEnd(params?: ?{animated?: ?boolean, ...}) {
    console.log(params);
  }
  _keyExtractor = (items: ItemT | Array<ItemT>, index: number): string => {
    return String(index);
  };
  render(): React.Node { return null; }
}
export default FlatList;
`);
  });

  // === Indexed access type ===
  test("indexed access type in variable", async () => {
    await expectFlowPass(`
// @flow
type Props = {name: string, age: number};
let x: ?Props['name'] = null;
const f = (x: Props['age']): void => {};
`);
  });

  // === hook declaration ===
  test("Flow hook declaration", async () => {
    await expectFlowPass(`
// @flow strict-local
hook useCounter(initial: number) {
  const state = {count: initial};
  return state;
}
export default useCounter;
`);
  });

  // === declare component ===
  test("declare component stripped", async () => {
    await expectFlowPass(`
// @flow
declare component Greeting(name: string) renders React.Node;
const x = 1;
`);
  });

  // === component with renders clause ===
  test("component with renders clause", async () => {
    await expectFlowPass(`
// @flow strict-local
component App(name: string) renders React.Node {
  return null;
}
export default App;
`);
  });

  // === component with generics ===
  test("component with generic type params", async () => {
    await expectFlowPass(`
// @flow strict-local
component List<T>(items: Array<T>, ...props: any) {
  return null;
}
export default List;
`);
  });

  // === JSX spread attribute (이전 regex 오스캔 버그) ===
  test("JSX spread attribute in function", async () => {
    await expectFlowPass(`
// @flow
function Wrapper(props: {children: any}) {
  return <Inner {...props} extra={true} />;
}
`);
  });

  // === nullable generic + optional chaining ===
  test("nullable generic type with optional chaining", async () => {
    await expectFlowPass(`
// @flow
type Config = {width?: number, height?: number};
function getSize(style: ?Config): number {
  return style?.width ?? 0;
}
`);
  });

  // === import type / export type ===
  test("import type and export type", async () => {
    await expectFlowPass(`
// @flow
import type {Node} from 'react';
export type {Node};
const x: Node = null;
`);
  });

  // === Flow interface ===
  test("Flow interface declaration", async () => {
    await expectFlowPass(`
// @flow
interface Greeter {
  greet(name: string): string;
}
const g: Greeter = {greet: (n) => n};
`);
  });

  // === opaque type ===
  test("opaque type declaration", async () => {
    await expectFlowPass(`
// @flow
opaque type ID = string;
const id: ID = "abc";
`);
  });

  // === declare module ===
  test("declare module stripped", async () => {
    await expectFlowPass(`
// @flow
declare module 'react-native' {
  declare export var View: any;
  declare export var Text: any;
}
const x = 1;
`);
  });
});
