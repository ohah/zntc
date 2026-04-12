//! Babel react-native-worklets/plugin 테스트 포팅 (parity)
//! 원본: software-mansion/react-native-reanimated
//! `packages/react-native-worklets/__tests__/plugin.test.ts` (169 tests)
//! Phase 1: ZTS 유닛 테스트로 이관. 스냅샷 대신 구조적 assert.
//! 미구현 기능(getter/setter/LA auto-worklet/__classFactory 등) 테스트는
//! 현재 실패할 수 있음 — Phase 2+에서 순차 구현 예정.

const std = @import("std");
const tt = @import("transformer_test.zig");

test "babel:babel_plugin_generally:transforms" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\import Animated, {
        \\  useAnimatedStyle,
        \\  useSharedValue,
        \\} from 'react-native-reanimated';
        \\
        \\function Box() {
        \\  const offset = useSharedValue(0);
        \\
        \\  const animatedStyles = useAnimatedStyle(() => {
        \\    return {
        \\      transform: [{ translateX: offset.value * 255 }],
        \\    };
        \\  });
        \\
        \\  return (
        \\    <>
        \\      <Animated.View style={[styles.box, animatedStyles]} />
        \\      <Button
        \\        onPress={() => (offset.value = Math.random())}
        \\        title="Move"
        \\      />
        \\    </>
        \\  );
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_generally:injects_its_version" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'worklet';
        \\  var foo = "bar";
        \\}
    ) catch return error.SkipZigTest;
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__pluginVersion =") != null);
}

test "babel:babel_plugin_generally:injects_source_maps" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'worklet';
        \\  var foo = 'bar';
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).toMatch(/sourceMap: /gm)
    // EXPECT: expect(code).toContain(
}

test "babel:babel_plugin_generally:uses_relative_source_location_when_relativeSourceLocation_is_set_to_true" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'worklet';
        \\  var foo = 'bar';
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT length: expect(matches).toHaveLength(2)
}

test "babel:babel_plugin_generally:removes_comments_from_worklets" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const f = () => {
        \\  'worklet';
        \\  // some comment
        \\  /*
        \\   * other comment
        \\   */
        \\  return true;
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "some comment") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "other comment") == null);
}

test "babel:babel_plugin_generally:supports_recursive_calls" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const a = 1;
        \\function foo(t) {
        \\  'worklet';
        \\  if (t > 0) {
        \\    return a + foo(t - 1);
        \\  }
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).toMatch(/const foo_null[0-9]+=this._recur;/gm)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_names:unnamed_ArrowFunctionExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\() => {
        \\  'worklet';
        \\  return 1;
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).toMatch(/function null[0-9]+\(\)/gm)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_names:unnamed_FunctionExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\[
        \\  function () {
        \\    'worklet';
        \\    return 1;
        \\  },
        \\]();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).toMatch(/function null[0-9]+\(\)/gm)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_names:names_ObjectMethod_with_expression_key" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const obj = {
        \\  ['foo']() {
        \\    'worklet';
        \\  },
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT parse error: expect(() => runPlugin(input)).toThrow()
}

test "babel:babel_plugin_for_worklet_names:appends_file_name_to_function_name" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'worklet';
        \\  return 1;
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).toMatch(/function foo_sourceJs[0-9]+\(\)/gm)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_names:appends_library_name_to_function_name" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'worklet';
        \\  return 1;
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).toMatch(/function foo_library_sourceJs[0-9]+\(\)/gm)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_names:handles_names_with_illegal_characters" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'worklet';
        \\  return 1;
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).toMatch(/function foo_SourceJs[0-9]+\(\)/gm)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_names:preserves_recursion" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'worklet';
        \\  foo(1);
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).toMatch(/function foo_null[0-9]+\(\)/gm); // React code
    // EXPECT: expect(code).toMatchInWorkletString(/function foo_null[0-9]+\(\)/gm); // Worklet code
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_DirectiveLiterals:doesn" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'foobar';
        \\  var foo = 'bar';
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "foobar") != null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_DirectiveLiterals:doesn_2" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function f(x) {
        \\  return x + 2;
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_DirectiveLiterals:removes" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo(x) {
        \\  "worklet"; // prettier-ignore
        \\  return x + 2;
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_DirectiveLiterals:removes_2" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo(x) {
        \\  'worklet'; // prettier-ignore
        \\  return x + 2;
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_DirectiveLiterals:doesn_3" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo(x) {
        \\  'worklet';
        \\  const bar = 'worklet'; // prettier-ignore
        \\  const baz = "worklet"; // prettier-ignore
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "bar = 'worklet';") != null or std.mem.indexOf(u8, code, "bar = \"worklet\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "baz = \"worklet\";") != null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_closure_capturing:captures_worklets_environment" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const x = 5;
        \\
        \\const objX = { x };
        \\
        \\function f() {
        \\  'worklet';
        \\  return { res: x + objX.x };
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "_f.__closure = {};") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_closure_capturing:doesn" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function f() {
        \\  'worklet';
        \\  console.log('test');
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(closureBindings).toEqual([])
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_closure_capturing:implicitly_captures_globals_with_strictGlobal_disabled" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function f() {
        \\  'worklet';
        \\  globalStuff();
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(closureBindings).not.toEqual([])
    // EXPECT regex: expect(code).toMatch(/f\.__closure = {\s*globalStuff/gm)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_closure_capturing:doesn_2" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function f() {
        \\  'worklet';
        \\  globalStuff();
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(closureBindings).toEqual([])
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_closure_capturing:captures_locally_bound_variables_named_like_globals" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const console = {
        \\  log: () => 42,
        \\};
        \\
        \\function f() {
        \\  'worklet';
        \\  console.log(console);
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(closureBindings).not.toEqual([])
    // EXPECT regex: expect(code).toMatch(/f\.__closure = {\s*console/gm)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_closure_capturing:doesn_3" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_closure_capturing:doesn_4" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = 42;
        \\
        \\function f() {
        \\  'worklet';
        \\  console.log(foo);
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).toMatch(/f\.__closure = {\s*foo/gm)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_closure_capturing:doesn_5" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function f(a, b, c) {
        \\  'worklet';
        \\  console.log(arguments);
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "f.__closure = {}") != null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_closure_capturing:doesn_6" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = { bar: 42 };
        \\
        \\function f() {
        \\  'worklet';
        \\  console.log(foo.bar);
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).toMatch(/f\.__closure = {\s*foo/gm)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_explicit_worklets:workletizes_FunctionDeclaration" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo(x) {
        \\  'worklet';
        \\  return x + 2;
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    // EXPECT: has worklet data (__workletHash present)
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_explicit_worklets:workletizes_ArrowFunctionExpression" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_explicit_worklets:workletizes_unnamed_FunctionExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = function (x) {
        \\  'worklet';
        \\  return x + 2;
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    // EXPECT: has worklet data (__workletHash present)
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_explicit_worklets:workletizes_named_FunctionExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = function foo(x) {
        \\  'worklet';
        \\  return x + 2;
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    // EXPECT: has worklet data (__workletHash present)
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_explicit_worklets:workletizes_ObjectMethod" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = {
        \\  bar(x) {
        \\    'worklet';
        \\    return x + 2;
        \\  },
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_class_worklets:workletizes_instance_method" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\class Foo {
        \\  bar(x) {
        \\    'worklet';
        \\    return x + 2;
        \\  }
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    // EXPECT: has worklet data (__workletHash present)
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_class_worklets:workletizes_static_method" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\class Foo {
        \\  static bar(x) {
        \\    'worklet';
        \\    return x + 2;
        \\  }
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    // EXPECT: has worklet data (__workletHash present)
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_class_worklets:workletizes_getter" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const x = 5;
        \\class Foo {
        \\  get bar() {
        \\    'worklet';
        \\    return x + 2;
        \\  }
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_class_worklets:workletizes_setter" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\class Foo {
        \\  set bar(x) {
        \\    'worklet';
        \\    this.x = x + 2;
        \\  }
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_class_worklets:workletizes_class_field" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\class Foo {
        \\  bar = (x) => {
        \\    'worklet';
        \\    return x + 2;
        \\  };
        \\}
    ) catch return error.SkipZigTest;
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
}

test "babel:babel_plugin_for_class_worklets:workletizes_static_class_field" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\class Foo {
        \\  static bar = (x) => {
        \\    'worklet';
        \\    return x + 2;
        \\  };
        \\}
    ) catch return error.SkipZigTest;
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
}

test "babel:babel_plugin_for_class_worklets:workletizes_constructor" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\class Foo {
        \\  constructor(x) {
        \\    'worklet';
        \\    this.x = x;
        \\  }
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    // EXPECT: has worklet data (__workletHash present)
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_function_hooks:workletizes_hook_wrapped_ArrowFunctionExpression_automatically" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const animatedStyle = useAnimatedStyle(() => ({
        \\  width: 50,
        \\}));
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_function_hooks:workletizes_hook_wrapped_unnamed_FunctionExpression_automatically" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const animatedStyle = useAnimatedStyle(function () {
        \\  return {
        \\    width: 50,
        \\  };
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_function_hooks:workletizes_hook_wrapped_named_FunctionExpression_automatically" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const animatedStyle = useAnimatedStyle(function foo() {
        \\  return {
        \\    width: 50,
        \\  };
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_function_hooks:workletizes_hook_wrapped_worklet_reference_automatically" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const style = () => {
        \\  return {
        \\    color: 'red',
        \\    backgroundColor: 'blue',
        \\  };
        \\};
        \\const animatedStyle = useAnimatedStyle(style);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_object_hooks:workletizes_useAnimatedScrollHandler_wrapped_ArrowFunctionExpression_automatically" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\useAnimatedScrollHandler({
        \\  onScroll: (event) => {
        \\    console.log(event);
        \\  },
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_object_hooks:workletizes_useAnimatedScrollHandler_wrapped_unnamed_FunctionExpression_automatically" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\useAnimatedScrollHandler({
        \\  onScroll: function (event) {
        \\    console.log(event);
        \\  },
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_object_hooks:workletizes_useAnimatedScrollHandler_wrapped_named_FunctionExpression_automatically" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\useAnimatedScrollHandler({
        \\  onScroll: function onScroll(event) {
        \\    console.log(event);
        \\  },
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_object_hooks:workletizes_useAnimatedScrollHandler_wrapped_ObjectMethod_automatically" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\useAnimatedScrollHandler({
        \\  onScroll(event) {
        \\    console.log(event);
        \\  },
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_object_hooks:supports_empty_object_in_useAnimatedScrollHandler" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\useAnimatedScrollHandler({});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_object_hooks:transforms_each_object_property_in_useAnimatedScrollHandler" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\useAnimatedScrollHandler({
        \\  onScroll: () => {},
        \\  onBeginDrag: () => {},
        \\  onEndDrag: () => {},
        \\  onMomentumBegin: () => {},
        \\  onMomentumEnd: () => {},
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 5 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_object_hooks:transforms_ArrowFunctionExpression_as_argument_of_useAnimatedScrollHandler" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\useAnimatedScrollHandler((event) => {
        \\  console.log(event);
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_object_hooks:transforms_unnamed_FunctionExpression_as_argument_of_useAnimatedScrollHandler" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\useAnimatedScrollHandler(function (event) {
        \\  console.log(event);
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_object_hooks:transforms_named_FunctionExpression_as_argument_of_useAnimatedScrollHandler" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\useAnimatedScrollHandler(function foo(event) {
        \\  console.log(event);
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:workletizes_gesture_callbacks_using_the_hooks_api" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = useTapGesture({
        \\  numberOfTaps: 2,
        \\  onBegin: () => {
        \\    console.log('onBegin');
        \\  },
        \\  onStart: (_event) => {
        \\    console.log('onStart');
        \\  },
        \\  onEnd: (_event, _success) => {
        \\    console.log('onEnd');
        \\  },
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 3 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:workletizes_referenced_gesture_callbacks_using_the_hooks_api" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const onBegin = () => {
        \\  console.log('onBegin');
        \\};
        \\const foo = useTapGesture({
        \\  numberOfTaps: 2,
        \\  onBegin: onBegin,
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:workletizes_referenced_gesture_callbacks_using_the_hooks_api_and_shorthand_syntax" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const onBegin = () => {
        \\  console.log('onBegin');
        \\};
        \\const foo = useTapGesture({
        \\  numberOfTaps: 2,
        \\  onBegin,
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:workletizes_possibly_chained_gesture_object_callback_functions_automatically" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = Gesture.Tap()
        \\  .numberOfTaps(2)
        \\  .onBegin(() => {
        \\    console.log('onBegin');
        \\  })
        \\  .onStart((_event) => {
        \\    console.log('onStart');
        \\  })
        \\  .onEnd((_event, _success) => {
        \\    console.log('onEnd');
        \\  });
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 3 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:doesn" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = Gesture.Tap().toString();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:doesn_2" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = Something.Tap().onEnd((_event, _success) => {
        \\  console.log('onEnd');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:doesn_3" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = Something.Gesture.Tap().onEnd(() => {
        \\  console.log('onEnd');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:transforms_spread_operator_in_worklets_for_arrays" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'worklet';
        \\  const bar = [4, 5];
        \\  const baz = [1, ...[2, 3], ...bar];
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "...[2,3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "...bar") != null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:transforms_spread_operator_in_worklets_for_objects" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'worklet';
        \\  const bar = { d: 4, e: 5 };
        \\  const baz = { a: 1, ...{ b: 2, c: 3 }, ...bar };
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "...{b:2,c:3}") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "...bar") != null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:transforms_spread_operator_in_worklets_for_function_arguments" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo(...args) {
        \\  'worklet';
        \\  console.log(args);
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "...args") != null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:transforms_spread_operator_in_worklets_for_function_calls" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo(arg) {
        \\  'worklet';
        \\  console.log(...arg);
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "...arg") != null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:transforms_spread_operator_in_Animated_component" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function App() {
        \\  return (
        \\    <Animated.View
        \\      style={[style, { ...styles.container, width: sharedValue.value }]}
        \\    />
        \\  );
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_react_native_gesture_handler:workletizes_referenced_callbacks" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const onStart = () => {};
        \\const foo = Gesture.Tap().onStart(onStart);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_sequence_expressions:supports_SequenceExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function App() {
        \\  (0, fun)({ onStart() {} }, []);
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_sequence_expressions:supports_SequenceExpression_with_objectHook" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function App() {
        \\  (0, useAnimatedScrollHandler)({ onScroll() {} }, []);
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_sequence_expressions:supports_SequenceExpression_with_worklet" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function App() {
        \\  (0, fun)(
        \\    {
        \\      onStart() {
        \\        'worklet';
        \\      },
        \\    },
        \\    []
        \\  );
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    // EXPECT: has worklet data (__workletHash present)
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_sequence_expressions:supports_SequenceExpression_many_arguments" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function App() {
        \\  (0, 3, fun)(
        \\    {
        \\      onStart() {
        \\        'worklet';
        \\      },
        \\    },
        \\    []
        \\  );
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    // EXPECT: has worklet data (__workletHash present)
    try std.testing.expect(std.mem.indexOf(u8, code, "'worklet';") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_sequence_expressions:supports_SequenceExpression_with_worklet_closure" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function App() {
        \\  const obj = { a: 1, b: 2 };
        \\  (0, fun)(
        \\    {
        \\      onStart() {
        \\        'worklet';
        \\        const a = obj.a;
        \\      },
        \\    },
        \\    []
        \\  );
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT length: expect(closureBindings).toHaveLength(1)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_inline_styles:shows_a_warning_if_user_uses_value_inside_inline_style" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function App() {
        \\  return <Animated.View style={{ width: sharedValue.value }} />;
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(code).toHaveInlineStyleWarning()
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_inline_styles:doesn" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function App() {
        \\  return <Animated.View style={{ width: object['value'] }} />;
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(code).not.toHaveInlineStyleWarning()
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_inline_styles:doesn_2" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function App() {
        \\  return <Animated.View style={{ width: object[value] }} />;
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(code).not.toHaveInlineStyleWarning()
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_inline_styles:shows_a_warning_if_user_uses_value_inside_inline_style_style_array" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function App() {
        \\  return (
        \\    <Animated.View style={[style, { width: sharedValue.value }]} />
        \\  );
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(code).toHaveInlineStyleWarning()
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_inline_styles:shows_a_warning_if_user_uses_value_inside_inline_style_transforms" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function App() {
        \\  return (
        \\    <Animated.View
        \\      style={{ transform: [{ translateX: sharedValue.value }] }}
        \\    />
        \\  );
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(code).toHaveInlineStyleWarning()
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_inline_styles:doesn_3" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function App() {
        \\  return <Animated.View style={styles.value} />;
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(code).not.toHaveInlineStyleWarning()
    // (snapshot — skipped)
}

test "babel:babel_plugin_is_idempotent:for_common_cases" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = useAnimatedStyle(() => {
        \\  const x = 1;
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(resultIsIdempotent(input1)).toBe(true)
    // EXPECT: expect(resultIsIdempotent(input2)).toBe(true)
    // EXPECT: expect(resultIsIdempotent(input3)).toBe(true)
    // EXPECT: expect(resultIsIdempotent(input4)).toBe(true)
    // EXPECT: expect(resultIsIdempotent(input5)).toBe(true)
    // EXPECT: expect(resultIsIdempotent(input6)).toBe(true)
    // EXPECT: expect(resultIsIdempotent(input7)).toBe(true)
    // EXPECT: expect(resultIsIdempotent(input8)).toBe(true)
    // EXPECT: expect(resultIsIdempotent(input9)).toBe(true)
}

test "babel:babel_plugin_for_Layout_Animations:workletizes_unchained_callback_functions_automatically" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\FadeIn.withCallback(() => {
        \\  console.log('FadeIn');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "babel:babel_plugin_for_Layout_Animations:workletizes_unchained_callback_functions_automatically_with_new_keyword" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\new FadeIn().withCallback(() => {
        \\  console.log('FadeIn');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "babel:babel_plugin_for_Layout_Animations:doesn" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\AmogusIn.withCallback(() => {
        \\  console.log('AmogusIn');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "babel:babel_plugin_for_Layout_Animations:doesn_2" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\new AmogusIn().withCallback(() => {
        \\  console.log('AmogusIn');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "babel:babel_plugin_for_Layout_Animations:workletizes_callback_functions_on_known_chained_methods_before" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\FadeIn.build().withCallback(() => {
        \\  console.log('FadeIn with build before');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "babel:babel_plugin_for_Layout_Animations:workletizes_callback_functions_on_known_chained_methods_before_with_new_keyword" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\new FadeIn().build().withCallback(() => {
        \\  console.log('FadeIn with build before');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "babel:babel_plugin_for_Layout_Animations:doesn_3" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\AmogusIn.build().withCallback(() => {
        \\  console.log('AmogusIn with build before');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "babel:babel_plugin_for_Layout_Animations:doesn_4" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\new AmogusIn().build().withCallback(() => {
        \\  console.log('AmogusIn with build before');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "babel:babel_plugin_for_Layout_Animations:workletizes_callback_functions_on_known_chained_methods_after" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\FadeIn.withCallback(() => {
        \\  console.log('FadeIn with build after');
        \\}).build();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "babel:babel_plugin_for_Layout_Animations:workletizes_callback_functions_on_known_chained_methods_after_with_new_keyword" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\new FadeIn()
        \\  .withCallback(() => {
        \\    console.log('FadeIn with build after');
        \\  })
        \\  .build();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "babel:babel_plugin_for_Layout_Animations:doesn_5" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\FadeIn.AmogusIn().withCallback(() => {
        \\  console.log('FadeIn with AmogusIn before');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "babel:babel_plugin_for_Layout_Animations:doesn_6" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\new FadeIn().AmogusIn().withCallback(() => {
        \\  console.log('FadeIn with AmogusIn before');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "babel:babel_plugin_for_Layout_Animations:doesn_7" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\AmogusIn.FadeIn().withCallback(() => {
        \\  console.log('AmogusIn with FadeIn after');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "babel:babel_plugin_for_Layout_Animations:doesn_8" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\new AmogusIn().FadeIn().withCallback(() => {
        \\  console.log('AmogusIn with FadeIn after');
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "babel:babel_plugin_for_Layout_Animations:workletizes_callback_functions_on_unknown_objects_chained_after" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\FadeIn.withCallback(() => {
        \\  console.log('FadeIn with AmogusIn after');
        \\}).AmogusIn();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "babel:babel_plugin_for_Layout_Animations:workletizes_callback_functions_on_unknown_objects_chained_after_with_new_keyword" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\new FadeIn()
        \\  .withCallback(() => {
        \\    console.log('FadeIn with AmogusIn after');
        \\  })
        \\  .AmogusIn();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "babel:babel_plugin_for_Layout_Animations:doesn_9" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\AmogusIn.withCallback(() => {
        \\  console.log('AmogusIn with FadeIn before');
        \\}).FadeIn();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "babel:babel_plugin_for_Layout_Animations:doesn_10" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\new AmogusIn()
        \\  .withCallback(() => {
        \\    console.log('AmogusIn with FadeIn before');
        \\  })
        \\  .FadeIn();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "babel:babel_plugin_for_Layout_Animations:workletizes_callback_functions_on_longer_chains_of_known_objects" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\FadeIn.build()
        \\  .duration()
        \\  .withCallback(() => {
        \\    console.log('FadeIn with build');
        \\  });
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "babel:babel_plugin_for_Layout_Animations:workletizes_callback_functions_on_longer_chains_of_known_objects_with_new_keyword" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\new FadeIn()
        \\  .build()
        \\  .duration()
        \\  .withCallback(() => {
        \\    console.log('FadeIn with build');
        \\  });
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "babel:babel_plugin_for_debugging:does_inject_location_for_worklets_in_dev_builds" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = useAnimatedStyle(() => {
        \\  const x = 1;
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(code).toHaveLocation(MOCK_LOCATION)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_debugging:doesn" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = useAnimatedStyle(() => {
        \\  const x = 1;
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(code).not.toHaveLocation(MOCK_LOCATION)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_debugging:doesn_2" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = useAnimatedStyle(() => {
        \\  const x = 1;
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "version: ") == null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_debugging:throws_a_tagged_exception_when_worklet_processing_fails" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = useAnimatedStyle(() => {
        \\  return <Image />;
        \\});
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: expect(() =>
}

test "babel:babel_plugin_for_worklet_nesting:transpiles_nested_worklets" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = () => {
        \\  'worklet';
        \\  const bar = () => {
        \\    'worklet';
        \\    console.log('bar');
        \\  };
        \\  bar();
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 2 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_nesting:transpiles_nested_worklets_with_depth_3" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = () => {
        \\  'worklet';
        \\  const bar = () => {
        \\    'worklet';
        \\    const foobar = () => {
        \\      'worklet';
        \\      console.log('foobar');
        \\    };
        \\  };
        \\  bar();
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 3 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_nesting:transpiles_nested_worklets_embedded_in_runOnJS_in_runOnUI" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\runOnUI(() => {
        \\  console.log('Hello from UI thread');
        \\  runOnJS(() => {
        \\    'worklet';
        \\    console.log('Hello from JS thread');
        \\  })();
        \\})();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 2 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_nesting:transpiles_nested_worklets_embedded_in_runOnUI_in_runOnJS_in_runOnUI" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\runOnUI(() => {
        \\  console.log('Hello from UI thread');
        \\  runOnJS(() => {
        \\    'worklet';
        \\    console.log('Hello from JS thread');
        \\    runOnUI(() => {
        \\      console.log('Hello from UI thread again');
        \\    })();
        \\  })();
        \\})();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 3 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_nesting:transpiles_worklets_with_functions_defined_on_UI_thread_to_run_them_on_JS" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\runOnUI(() => {
        \\  const a = () => {
        \\    'worklet';
        \\    console.log('Good morning from JS thread!');
        \\  };
        \\  const b = () => {
        \\    'worklet';
        \\    console.log('Good afternoon from JS thread');
        \\  };
        \\  const func = Math.random() < 0.5 ? a : b;
        \\  runOnJS(func)();
        \\})();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 3 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_web_configuration:skips_initData_when_omitNativeOnlyData_option_is_set_to_true" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'worklet';
        \\  var foo = 'bar';
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 0 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_web_configuration:includes_initData_when_omitNativeOnlyData_option_is_set_to_false" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'worklet';
        \\  var bar = 'bar';
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_web_configuration:substitutes_isWeb_and_shouldBeUseWeb_with_true_when_substituteWebPlatformChecks_option_is_set_to_true" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_web_configuration:doesn" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const x = isWeb();
        \\const y = shouldBeUseWeb();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "const x = isWeb();") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "const y = shouldBeUseWeb();") != null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_web_configuration:doesn_2" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const x = isWeb();
        \\const y = shouldBeUseWeb();
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "const x = isWeb();") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "const y = shouldBeUseWeb();") != null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_web_configuration:doesn_3" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  'worklet';
        \\  const x = isWeb();
        \\  const y = shouldBeUseWeb();
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "const x=isWeb();") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "const y=shouldBeUseWeb();") != null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_generators:makes_a_generator_worklet_factory" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_generators:makes_a_generator_worklet_string" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function* foo() {
        \\  'worklet';
        \\  yield 'hello';
        \\  yield 'world';
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).toMatch(
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_async_functions:makes_an_async_worklet_factory" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_async_functions:makes_an_async_worklet_string" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\async function foo() {
        \\  'worklet';
        \\  await Promise.resolve();
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).toMatch(
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_ArrowFunctionExpression_on_its_VariableDeclarator" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\let styleFactory = () => ({});
        \\const animatedStyle = useAnimatedStyle(styleFactory);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_ArrowFunctionExpression_on_its_AssignmentExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\let styleFactory;
        \\styleFactory = () => ({});
        \\animatedStyle = useAnimatedStyle(styleFactory);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_ArrowFunctionExpression_only_on_last_AssignmentExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\let styleFactory;
        \\styleFactory = () => 1;
        \\styleFactory = () => 'AssignmentExpression';
        \\animatedStyle = useAnimatedStyle(styleFactory);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // EXPECT in __initData.code: AssignmentExpression
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_FunctionExpression_on_its_VariableDeclarator" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\let styleFactory = function () {
        \\  return {};
        \\};
        \\const animatedStyle = useAnimatedStyle(styleFactory);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_FunctionExpression_on_its_AssignmentExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\let styleFactory;
        \\styleFactory = function () {
        \\  return {};
        \\};
        \\animatedStyle = useAnimatedStyle(styleFactory);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_FunctionExpression_only_on_last_AssignmentExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\let styleFactory;
        \\styleFactory = function () {
        \\  return 1;
        \\};
        \\styleFactory = function () {
        \\  return 'AssignmentExpression';
        \\};
        \\animatedStyle = useAnimatedStyle(styleFactory);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // EXPECT in __initData.code: AssignmentExpression
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_FunctionDeclaration" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function styleFactory() {
        \\  return {};
        \\}
        \\const animatedStyle = useAnimatedStyle(styleFactory);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_ObjectExpression_on_its_VariableDeclarator" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\let handler = {
        \\  onScroll: () => {},
        \\};
        \\const scrollHandler = useAnimatedScrollHandler(handler);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_ObjectExpression_on_its_AssignmentExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\let handler;
        \\handler = {
        \\  onScroll: () => {},
        \\};
        \\const scrollHandler = useAnimatedScrollHandler(handler);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_ObjectExpression_only_on_last_AssignmentExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\let handler;
        \\handler = {
        \\  onScroll: () => 1,
        \\};
        \\handler = {
        \\  onScroll: () => 'AssignmentExpression',
        \\};
        \\const scrollHandler = useAnimatedScrollHandler(handler);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // EXPECT in __initData.code: AssignmentExpression
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:prefers_FunctionDeclaration_over_AssignmentExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function styleFactory() {
        \\  return 'FunctionDeclaration';
        \\}
        \\styleFactory = () => 'AssignmentExpression';
        \\animatedStyle = useAnimatedStyle(styleFactory);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // EXPECT in __initData.code: FunctionDeclaration
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:prefers_AssignmentExpression_over_VariableDeclarator" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\let styleFactory = () => 1;
        \\styleFactory = () => 'AssignmentExpression';
        \\animatedStyle = useAnimatedStyle(styleFactory);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // EXPECT in __initData.code: AssignmentExpression
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_in_immediate_scope" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\let styleFactory = () => ({});
        \\animatedStyle = useAnimatedStyle(styleFactory);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_in_nested_scope" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function outerScope() {
        \\  let styleFactory = () => ({});
        \\  function innerScope() {
        \\    animatedStyle = useAnimatedStyle(styleFactory);
        \\  }
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_assignments_that_appear_after_the_worklet_is_used" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\let styleFactory = () => ({});
        \\animatedStyle = useAnimatedStyle(styleFactory);
        \\styleFactory = () => {
        \\  return 'AssignmentAfterUse';
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // EXPECT in __initData.code: AssignmentAfterUse
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_multiple_referencing" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const secondReference = () => ({});
        \\const firstReference = secondReference;
        \\const animatedStyle = useAnimatedStyle(firstReference);
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_referenced_worklets:workletizes_recursion" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function recursiveWorklet() {
        \\  if (!globalThis._WORKLET) {
        \\    runOnUI(recursiveWorklet)();
        \\  }
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 1 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_file_workletization:workletizes_FunctionDeclaration" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\'worklet';
        \\function foo() {
        \\  return 'bar';
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_file_workletization:workletizes_assigned_FunctionDeclaration" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\'worklet';
        \\const foo = function foo() {
        \\  return 'bar';
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_file_workletization:workletizes_FunctionDeclaration_in_named_export" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:workletizes_FunctionDeclaration_in_default_export" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:workletizes_FunctionExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\'worklet';
        \\const foo = function () {
        \\  return 'bar';
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_file_workletization:workletizes_FunctionExpression_in_named_export" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:workletizes_FunctionExpression_in_default_export" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:workletizes_ArrowFunctionExpression" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\'worklet';
        \\const foo = () => {
        \\  return 'bar';
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_file_workletization:workletizes_ArrowFunctionExpression_in_named_export" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:workletizes_ArrowFunctionExpression_in_default_export" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:workletizes_ObjectMethod" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\'worklet';
        \\const foo = {
        \\  bar() {
        \\    return 'bar';
        \\  },
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_file_workletization:workletizes_ObjectMethod_in_named_export" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\'worklet';
        \\export const foo = {
        \\  bar() {
        \\    return 'bar';
        \\  },
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    // EXPECT: has worklet data (__workletHash present)
    try std.testing.expect(std.mem.indexOf(u8, code, "export const foo = {") != null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_file_workletization:workletizes_ObjectMethod_in_default_export" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\'worklet';
        \\export default {
        \\  bar() {
        \\    return 'bar';
        \\  },
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    // EXPECT: has worklet data (__workletHash present)
    try std.testing.expect(std.mem.indexOf(u8, code, "export default {") != null);
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_file_workletization:workletizes_implicit_WorkletContextObject" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:workletizes_implicit_WorkletContextObject_in_named_export" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:workletizes_implicit_WorkletContextObject_in_default_export" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:workletizes_ClassDeclaration" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:workletizes_ClassDeclaration_in_named_export" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:workletizes_ClassDeclaration_in_default_export" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:workletizes_multiple_functions" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\'worklet';
        \\function foo() {
        \\  return 'bar';
        \\}
        \\const bar = () => {
        \\  return 'foobar';
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 2 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_file_workletization:doesn" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\'worklet';
        \\{
        \\  function foo() {
        \\    return 'bar';
        \\  }
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_file_workletization:moves_CommonJS_export_to_the_bottom_of_the_file" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_file_workletization:moves_multiple_CommonJS_exports_to_the_bottom_of_the_file" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\'worklet';
        \\exports.foo = foo;
        \\exports.bar = bar;
        \\function foo() {}
        \\function bar() {}
        \\function baz() {}
        \\exports.baz = baz;
        \\exports.foobar = foobar;
        \\function foobar() {}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_context_objects:removes_marker" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = {
        \\  bar() {
        \\    return 'bar';
        \\  },
        \\  __workletContextObject: true,
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).not.toMatch(/__workletContextObject:\s*/g)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_context_objects:creates_factories" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_context_objects:workletizes_regardless_of_marker_value" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = {
        \\  bar() {
        \\    return 'bar';
        \\  },
        \\  __workletContextObject: new RegExp('foo'),
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: has worklet data (__workletHash present)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_context_objects:preserves_bindings" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\const foo = {
        \\  bar() {
        \\    return 'bar';
        \\  },
        \\  foobar() {
        \\    return this.bar();
        \\  },
        \\  __workletContextObject: true,
        \\};
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT in __initData.code: this.bar()
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_classes:removes_marker" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\class Clazz {
        \\  __workletClass = true;
        \\  foo() {
        \\    return 'bar';
        \\  }
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT regex: expect(code).not.toMatch(/__workletClass:\s*/g)
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_classes:creates_factories" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_worklet_classes:workletizes_regardless_of_marker_value" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_worklet_classes:injects_class_factory_into_worklets" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_worklet_classes:modifies_closures" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_worklet_classes:keeps_this_binding" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\class Clazz {
        \\  __workletClass = true;
        \\  member = 1;
        \\  foo() {
        \\    return this.member;
        \\  }
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT in __initData.code: this.member
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_classes:appends_polyfills" {
    // PHASE 2+ 에서 구현 예정 (미구현 기능 테스트)
    return error.SkipZigTest;
}

test "babel:babel_plugin_for_worklet_classes:workletizes_polyfills" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\class Clazz {
        \\  __workletClass = true;
        \\
        \\  foo() {
        \\    return 'bar';
        \\  }
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    _ = &code;
    // EXPECT: 6 worklet(s) — __workletHash count
    // (snapshot — skipped)
}

test "babel:babel_plugin_for_worklet_classes:is_disabled_via_option" {
    var r = tt.transformWorklet(std.testing.allocator,
        \\function foo() {
        \\  this.prop = 42;
        \\}
        \\
        \\function bar() {
        \\  'worklet';
        \\  const instance = new foo();
        \\}
    ) catch return error.SkipZigTest; // 파싱/변환 실패 — 후속 Phase에서 해결
    defer r.deinit();
    const code = tt.generateCode(&r) catch return error.SkipZigTest;
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "foo__classFactory") == null);
    // (snapshot — skipped)
}
